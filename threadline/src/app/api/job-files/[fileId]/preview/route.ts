import { spawn } from "node:child_process";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

type RouteContext = { params: Promise<{ fileId: string }> };

const extensions: Record<string, string> = {
  PDF: "pdf", PNG: "png", JPEG: "jpg", SVG: "svg", DOCX: "docx",
  XLSX: "xlsx", PPTX: "pptx", CDR: "cdr", AI: "ai", PSD: "psd",
};

function htmlError(message: string, status: number) {
  const safeMessage = message.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character] ?? character);
  return new Response(
    `<!doctype html><html lang="id"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pratinjau file</title><body style="font:15px system-ui,sans-serif;padding:2rem;color:#27272a;background:#fafafa"><h2>Pratinjau tidak tersedia</h2><p>${safeMessage}</p></body></html>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } },
  );
}

function runCommand(command: string, args: string[], timeoutMs = 45_000): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "ignore" });
    let settled = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      settled = true;
      reject(new Error("Konversi pratinjau melewati batas waktu."));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      if (code === 0) resolve();
      else reject(new Error("Format ini gagal dikonversi."));
    });
  });
}

async function officePreview(inputPath: string, workDir: string) {
  const profileDir = path.join(workDir, "office-profile");
  const office = process.env.THREADLINE_OFFICE_BIN ?? "soffice";
  await runCommand(office, [
    "--headless", "--norestore", "--nodefault", "--nolockcheck",
    `-env:UserInstallation=file://${profileDir}`,
    "--convert-to", "pdf", "--outdir", workDir, inputPath,
  ]);
  const outputPath = path.join(workDir, `${path.parse(inputPath).name}.pdf`);
  if ((await stat(outputPath).catch(() => null))?.size) return { path: outputPath, contentType: "application/pdf" };
  throw new Error("LibreOffice tidak menghasilkan pratinjau PDF untuk format ini.");
}

async function quickLookPreview(inputPath: string, workDir: string) {
  const outputDir = path.join(workDir, "quicklook");
  await mkdir(outputDir);
  const quickLook = process.env.THREADLINE_QUICKLOOK_BIN ?? "qlmanage";
  await runCommand(quickLook, ["-t", "-x", "-s", "1800", "-o", outputDir, inputPath]);
  const outputName = (await readdir(outputDir)).find((name) => name.toLowerCase().endsWith(".png"));
  if (!outputName) throw new Error("Quick Look tidak menghasilkan gambar pratinjau.");
  return { path: path.join(outputDir, outputName), contentType: "image/png" };
}

function fileResponse(body: BodyInit, contentType: string, filename: string) {
  const safeFilename = filename.replace(/[^a-zA-Z0-9._-]/g, "_");
  const contentSecurityPolicy = contentType === "image/svg+xml"
    ? "default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox; frame-ancestors 'self'"
    : "frame-ancestors 'self'; object-src 'none'; base-uri 'none'";
  return new Response(body, {
    headers: {
      "Content-Type": contentType,
      "Content-Disposition": `inline; filename="${safeFilename}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": contentSecurityPolicy,
    },
  });
}

export async function GET(_request: Request, { params }: RouteContext) {
  const { fileId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return htmlError("Masuk kembali untuk melihat file ini.", 401);

  const { data: file, error } = await supabase
    .from("job_files")
    .select("name,path,file_kind,size_bytes")
    .eq("id", fileId)
    .maybeSingle();
  if (error || !file) return htmlError("File tidak ditemukan atau Anda tidak memiliki akses.", 404);
  if (file.size_bytes > 1_073_741_824) return htmlError("Ukuran file melebihi batas pratinjau 1 GiB.", 413);

  const extension = extensions[file.file_kind];
  if (!extension) return htmlError("Format file ini belum didukung untuk pratinjau.", 415);

  const { data: signed, error: signedError } = await supabase.storage
    .from("job-files")
    .createSignedUrl(file.path, 60);
  if (signedError || !signed) return htmlError("Tautan file tidak dapat dibuat.", 500);

  const original = await fetch(signed.signedUrl, { cache: "no-store" });
  if (!original.ok || !original.body) return htmlError("File gagal diambil dari penyimpanan.", 502);
  const sizeHeader = Number(original.headers.get("content-length") ?? 0);
  if (sizeHeader > 1_073_741_824) return htmlError("Ukuran file melebihi batas pratinjau 1 GiB.", 413);

  if (["PDF", "PNG", "JPEG", "SVG"].includes(file.file_kind)) {
    const contentType = ({ PDF: "application/pdf", PNG: "image/png", JPEG: "image/jpeg", SVG: "image/svg+xml" } as const)[file.file_kind as "PDF" | "PNG" | "JPEG" | "SVG"];
    return fileResponse(original.body, contentType, file.name);
  }

  const workDir = await mkdtemp(path.join(tmpdir(), "threadline-preview-"));
  let keepWorkDir = false;
  try {
    const inputPath = path.join(workDir, `source.${extension}`);
    await pipeline(Readable.fromWeb(original.body as never), createWriteStream(inputPath));

    const renderers = file.file_kind === "PSD"
      ? [quickLookPreview, officePreview]
      : [officePreview, quickLookPreview];
    let rendered: { path: string; contentType: string } | null = null;
    for (const render of renderers) {
      try {
        rendered = await render(inputPath, workDir);
        break;
      } catch {
        // Try the next local renderer; neither renderer receives a public file URL.
      }
    }
    if (!rendered) {
      return htmlError("Server pratinjau belum memiliki converter yang cocok, atau file ini tidak dapat dibaca.", 415);
    }

    const output = createReadStream(rendered.path);
    output.once("close", () => { void rm(workDir, { recursive: true, force: true }); });
    keepWorkDir = true;
    const basename = path.parse(file.name).name.replace(/[^a-zA-Z0-9._-]/g, "_");
    const previewName = `${basename}.${rendered.contentType === "application/pdf" ? "pdf" : "png"}`;
    return fileResponse(Readable.toWeb(output) as ReadableStream, rendered.contentType, previewName);
  } catch {
    return htmlError("File gagal diproses untuk pratinjau. Pastikan file tidak rusak.", 422);
  } finally {
    if (!keepWorkDir) await rm(workDir, { recursive: true, force: true });
  }
}
