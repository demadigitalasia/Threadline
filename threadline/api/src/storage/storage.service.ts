import { BadRequestException, ConflictException, ForbiddenException, Injectable, OnModuleDestroy, OnModuleInit, ServiceUnavailableException } from "@nestjs/common";
import { CopyObjectCommand, DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { randomUUID } from "node:crypto";
import { PrismaService } from "../prisma/prisma.service";
import type { AuthIdentity } from "../auth/auth.service";

const BUCKETS = new Set(["job-files", "profile-photos", "finance-payment-proofs"]);
const UPLOAD_URL_TTL_SECONDS = 900;
const DOWNLOAD_URL_TTL_SECONDS = 900;

@Injectable()
export class StorageService implements OnModuleInit, OnModuleDestroy {
  private readonly client: S3Client | null;
  private readonly bucketName: string;
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly prisma: PrismaService) {
    const endpoint = process.env.R2_ENDPOINT;
    const accessKeyId = process.env.R2_ACCESS_KEY_ID;
    const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
    this.bucketName = process.env.R2_BUCKET ?? "threadline-private";
    this.client = endpoint && accessKeyId && secretAccessKey
      ? new S3Client({ endpoint, region: "auto", forcePathStyle: true, credentials: { accessKeyId, secretAccessKey } })
      : null;
  }

  onModuleInit() {
    this.cleanupTimer = setInterval(() => { void this.cleanupExpiredUploads(); }, 15 * 60 * 1000);
  }

  onModuleDestroy() {
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
    this.client?.destroy();
  }

  async createUploadUrl(identity: AuthIdentity, input: { bucket: string; path: string; size: number; contentType?: string }) {
    const client = this.requireClient();
    const { bucket, path, size } = this.validate(input);
    const contentType = input.contentType?.trim().slice(0, 200) || "application/octet-stream";
    await this.authorizeUpload(identity, bucket, path, size, contentType);
    await this.assertObjectKeyUnused(bucket, path);
    const intentId = randomUUID();
    const stagingKey = `__pending/${bucket}/${intentId}`;
    await this.withService(async (tx) => tx.$executeRaw`
      INSERT INTO public.threadline_upload_intents(id, user_id, bucket_id, object_path, staging_key, size_bytes, content_type, expires_at)
      VALUES (${intentId}::uuid, ${identity.id}::uuid, ${bucket}, ${path}, ${stagingKey}, ${size}, ${contentType}, ${new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000)})
    `);
    const command = new PutObjectCommand({ Bucket: this.bucketName, Key: stagingKey, ContentType: contentType, ContentLength: size });
    const url = await getSignedUrl(client, command, { expiresIn: UPLOAD_URL_TTL_SECONDS, signableHeaders: new Set(["content-type", "content-length"]) });
    return { uploadUrl: url, intentId, expiresIn: UPLOAD_URL_TTL_SECONDS, requiredHeaders: { "content-type": contentType } };
  }

  async completeUpload(identity: AuthIdentity, input: { intentId: string }) {
    const client = this.requireClient();
    if (!/^[0-9a-f-]{36}$/i.test(input.intentId)) throw new BadRequestException("Upload intent tidak valid");
    const intent = await this.claimUploadIntent(identity, input.intentId);
    const { bucket_id: bucket, object_path: path, staging_key: stagingKey, size_bytes: storedSize, content_type: contentType } = intent;
    const size = Number(storedSize);
    try {
      const object = await client.send(new HeadObjectCommand({ Bucket: this.bucketName, Key: stagingKey }));
      if (Number(object.ContentLength) !== size || (object.ContentType && object.ContentType !== contentType)) {
        throw new BadRequestException("Ukuran atau tipe berkas tidak cocok dengan reservasi");
      }
      const copySource = `${encodeURIComponent(this.bucketName)}/${stagingKey.split("/").map(encodeURIComponent).join("/")}`;
      await client.send(new CopyObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path), CopySource: copySource, MetadataDirective: "COPY" }));
      await this.withUser(identity, async (tx) => tx.$executeRaw`
        INSERT INTO storage.objects(bucket_id, name, metadata)
        VALUES (${bucket}, ${path}, ${JSON.stringify({ size: String(size), mimetype: contentType, contentType })}::jsonb)
      `);
      await this.withService(async (tx) => tx.$executeRaw`UPDATE public.threadline_upload_intents SET status = 'complete' WHERE id = ${input.intentId}::uuid AND status = 'processing'`);
    } catch (error) {
      await client.send(new DeleteObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path) })).catch(() => undefined);
      await this.withService(async (tx) => tx.$executeRaw`UPDATE public.threadline_upload_intents SET status = 'failed' WHERE id = ${input.intentId}::uuid`);
      throw error;
    }
    await client.send(new DeleteObjectCommand({ Bucket: this.bucketName, Key: stagingKey })).catch(() => undefined);
    return { path, sizeBytes: size };
  }

  async signedUrl(identity: AuthIdentity, bucket: string, path: string) {
    const client = this.requireClient();
    this.validate({ bucket, path, size: 1 });
    const rows = await this.withUser(identity, async (tx) => tx.$queryRaw`
      SELECT 1 FROM storage.objects WHERE bucket_id = ${bucket} AND name = ${path} LIMIT 1
    ` as unknown[]);
    if (!rows.length) throw new ForbiddenException("Berkas tidak dapat diakses");
    const url = await getSignedUrl(client, new GetObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path) }), { expiresIn: DOWNLOAD_URL_TTL_SECONDS });
    return { signedUrl: url, expiresIn: DOWNLOAD_URL_TTL_SECONDS };
  }

  async remove(identity: AuthIdentity, bucket: string, paths: string[]) {
    const client = this.requireClient();
    if (!BUCKETS.has(bucket) || paths.length > 100) throw new BadRequestException("Permintaan penghapusan tidak valid");
    const uniquePaths = [...new Set(paths)];
    const candidates = await this.withUser(identity, async (tx) => {
      const allowed: string[] = [];
      for (const path of uniquePaths) {
        this.validate({ bucket, path, size: 1 });
        const rows = await tx.$queryRaw`SELECT name FROM storage.objects WHERE bucket_id = ${bucket} AND name = ${path}` as Array<{ name: string }>;
        if (rows[0]) allowed.push(rows[0].name);
      }
      return allowed;
    });
    await Promise.all(candidates.map(async (path) => {
      await client.send(new DeleteObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path) }));
    }));
    const deleted = await this.withUser(identity, async (tx) => {
      const result: string[] = [];
      for (const path of candidates) {
        const rows = await tx.$queryRaw`DELETE FROM storage.objects WHERE bucket_id = ${bucket} AND name = ${path} RETURNING name` as Array<{ name: string }>;
        result.push(...rows.map((row) => row.name));
      }
      return result;
    });
    return { deleted };
  }

  async removeAsService(bucket: string, path: string): Promise<boolean> {
    if (!this.client || !BUCKETS.has(bucket)) return false;
    try {
      await this.prisma.$transaction(async (tx) => {
        await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
        await tx.$queryRaw`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`;
        await tx.$queryRaw`DELETE FROM storage.objects WHERE bucket_id = ${bucket} AND name = ${path} RETURNING name`;
      });
      await this.client.send(new DeleteObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path) }));
      return true;
    } catch { return false; }
  }

  private async assertObjectKeyUnused(bucket: string, path: string) {
    const existing = await this.withService(async (tx) => tx.$queryRaw`SELECT 1 FROM storage.objects WHERE bucket_id = ${bucket} AND name = ${path} LIMIT 1` as unknown[]);
    if (existing.length) throw new ConflictException("Path penyimpanan sudah digunakan");
    try {
      await this.client!.send(new HeadObjectCommand({ Bucket: this.bucketName, Key: this.key(bucket, path) }));
      throw new ConflictException("Path penyimpanan sudah digunakan");
    } catch (error) {
      if (error instanceof ConflictException) throw error;
      const status = (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
      if (status !== 404) throw new ServiceUnavailableException("R2 tidak dapat memeriksa path unggahan");
    }
  }

  private async claimUploadIntent(identity: AuthIdentity, intentId: string) {
    const rows = await this.withService(async (tx) => tx.$queryRaw`
      UPDATE public.threadline_upload_intents SET status = 'processing'
      WHERE id = ${intentId}::uuid AND user_id = ${identity.id}::uuid AND status = 'pending' AND expires_at > now()
      RETURNING bucket_id, object_path, staging_key, size_bytes, content_type
    ` as Array<{ bucket_id: string; object_path: string; staging_key: string; size_bytes: bigint; content_type: string }>);
    if (!rows[0]) throw new ForbiddenException("Tautan unggahan tidak valid atau sudah digunakan");
    return rows[0];
  }

  private async cleanupExpiredUploads() {
    if (!this.client) return;
    try {
      const expired = await this.withService(async (tx) => tx.$queryRaw`
        DELETE FROM public.threadline_upload_intents WHERE expires_at < now() - interval '1 day'
        RETURNING staging_key
      ` as Array<{ staging_key: string }>);
      await Promise.all(expired.map(({ staging_key }) => this.client!.send(new DeleteObjectCommand({ Bucket: this.bucketName, Key: staging_key })).catch(() => undefined)));
    } catch { /* Retain intent rows; the next cleanup pass retries. */ }
  }

  private async authorizeUpload(identity: AuthIdentity, bucket: string, path: string, size: number, contentType: string) {
    const permitted = await this.withUser(identity, async (tx) => {
      const buckets = await tx.$queryRaw`SELECT file_size_limit, allowed_mime_types FROM storage.buckets WHERE id = ${bucket} AND public = false` as Array<{ file_size_limit: bigint | null; allowed_mime_types: string[] | null }>;
      const config = buckets[0];
      if (!config || (config.file_size_limit && BigInt(size) > config.file_size_limit)
        || (config.allowed_mime_types?.length && !config.allowed_mime_types.includes(contentType))) return false;
      let result: Array<{ allowed: boolean }>;
      if (bucket === "job-files") {
        result = await tx.$queryRaw`SELECT public.can_upload_job_file_object(${path}, ${JSON.stringify({ size: String(size), contentType, mimetype: contentType })}::jsonb) AS allowed` as Array<{ allowed: boolean }>;
      } else if (bucket === "profile-photos") {
        result = await tx.$queryRaw`SELECT public.is_freelance() AND (storage.foldername(${path}))[1] = auth.uid()::text AS allowed` as Array<{ allowed: boolean }>;
      } else {
        result = await tx.$queryRaw`SELECT (public.is_finance() OR public.is_super_admin()) AND split_part(${path}, '/', 1) = auth.uid()::text AS allowed` as Array<{ allowed: boolean }>;
      }
      return result[0]?.allowed === true;
    });
    if (!permitted) throw new ForbiddenException("Unggahan tidak diizinkan");
  }

  private async withUser<T>(identity: AuthIdentity, work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE authenticated");
      const claims = JSON.stringify({ sub: identity.id, role: "authenticated", aal: identity.aal });
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', ${identity.id}, true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', ${claims}, true)`;
      return work(tx);
    });
  }

  private async withService<T>(work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE service_role");
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true)`;
      return work(tx);
    });
  }

  private requireClient() {
    if (!this.client) throw new ServiceUnavailableException("R2 belum dikonfigurasi di API");
    return this.client;
  }

  private validate(input: { bucket: string; path: string; size: number }) {
    if (!BUCKETS.has(input.bucket) || !input.path || input.path.length > 1024 || input.path.startsWith("/")
      || input.path.split("/").some((part) => !part || part === "." || part === "..")
      || !Number.isSafeInteger(input.size) || input.size < 1 || input.size > 1_073_741_824) throw new BadRequestException("Berkas tidak valid");
    return { bucket: input.bucket, path: input.path, size: input.size };
  }

  private key(bucket: string, path: string) { return `${bucket}/${path}`; }
}
