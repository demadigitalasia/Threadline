import { BadRequestException, Injectable } from "@nestjs/common";
import { PrismaService } from "../prisma/prisma.service";
import type { AuthIdentity } from "../auth/auth.service";

const TABLES: Record<string, Set<string>> = {
  profiles: new Set(["id", "name", "avatar_path", "role", "is_active", "last_seen", "registration_status", "registration_review_reason", "availability_status", "availability_updated_at"]),
  profile_contacts: new Set(["profile_id", "whatsapp"]),
  jobs: new Set(["id", "tim", "jenis", "qty", "deadline", "fee", "approved_fee", "approved_for_profile_id", "assignee_profile_id", "status", "priority", "brief", "ref", "current_submission_id", "approved_submission_id", "created_at", "antre_since", "cancelled_at", "cancelled_by_profile_id", "cancellation_reason", "revision", "finished_at"]),
  job_files: new Set(["id", "job_id", "name", "path", "file_kind", "size_bytes", "uploaded_by_profile_id", "uploaded_at", "expired_at", "file_role", "reservation_id"]),
  job_submissions: new Set(["id", "job_id", "version", "submitted_by_profile_id", "submitted_at", "note", "decision", "review_note", "reviewed_by_profile_id", "reviewed_at", "submission_kind"]),
  job_submission_files: new Set(["submission_id", "job_file_id"]),
  job_events: new Set(["id", "job_id", "actor_profile_id", "event_type", "from_status", "to_status", "reason", "details", "created_at"]),
  chat_threads: new Set(["id", "freelance_profile_id", "created_at"]),
  chat_messages: new Set(["id", "thread_id", "sender_profile_id", "text", "created_at"]),
  app_settings: new Set(["id", "urgency_sla_hours", "max_active_jobs", "updated_at", "updated_by_profile_id"]),
  freelancer_bank_accounts: new Set(["profile_id", "bank_name", "account_number", "account_holder", "updated_at"]),
};
const UPSERT_KEYS: Record<string, string[]> = { freelancer_bank_accounts: ["profile_id"] };
const IDENTIFIER = /^[a-z][a-z0-9_]*$/;

export type DataQuery = {
  action: "select" | "insert" | "upsert" | "update" | "delete";
  columns?: string[];
  values?: Record<string, unknown> | Array<Record<string, unknown>>;
  filters?: Array<{ column: string; operator: "eq" | "neq"; value: unknown }>;
  order?: { column: string; ascending?: boolean };
  limit?: number;
  maybeSingle?: boolean;
};

@Injectable()
export class DataService {
  constructor(private readonly prisma: PrismaService) {}

  async execute(identity: AuthIdentity, table: string, query: DataQuery) {
    const columns = TABLES[table];
    if (!columns) throw new BadRequestException("Tabel tidak diizinkan");
    if (!query || !["select", "insert", "upsert", "update", "delete"].includes(query.action)) throw new BadRequestException("Operasi tidak valid");
    const filters = query.filters ?? [];
    for (const filter of filters) this.checkColumn(columns, filter.column);
    const selected = query.columns?.length ? query.columns : ["*"];
    for (const column of selected) if (column !== "*") this.checkColumn(columns, column);
    if (query.order) this.checkColumn(columns, query.order.column);
    const maxLimit = Math.max(1, Math.min(Number.isInteger(query.limit) ? query.limit! : 500, 5000));

    return this.withIdentity(identity, async (tx) => {
      if (query.action === "select") {
        const values: unknown[] = [];
        const where = this.whereClause(filters, values);
        const order = query.order ? ` ORDER BY ${this.ident(query.order.column)} ${query.order.ascending === false ? "DESC" : "ASC"}` : "";
        const rows = await tx.$queryRawUnsafe(`SELECT ${selected.map((column) => column === "*" ? "*" : this.ident(column)).join(", ")} FROM public.${this.ident(table)}${where}${order} LIMIT ${maxLimit + (query.maybeSingle ? 1 : 0)}`, ...values) as unknown[];
        if (query.maybeSingle) {
          if (rows.length > 1) return { data: null, error: { message: "Lebih dari satu baris ditemukan" } };
          return { data: rows[0] ?? null, error: null };
        }
        return { data: rows, error: null };
      }

      if (query.action === "insert" || query.action === "upsert") {
        const input = query.values;
        const rows = Array.isArray(input) ? input : input ? [input] : [];
        if (!rows.length || rows.length > 100) throw new BadRequestException("Data kosong atau terlalu banyak");
        const inserted: unknown[] = [];
        for (const row of rows) {
          const keys = Object.keys(row);
          if (!keys.length) throw new BadRequestException("Data kosong");
          keys.forEach((key) => this.checkColumn(columns, key));
          const params = keys.map((key) => row[key]);
          const placeholders = keys.map((_, index) => `$${index + 1}`).join(", ");
          const conflictKeys = UPSERT_KEYS[table];
          let conflict = "";
          if (query.action === "upsert") {
            if (!conflictKeys) throw new BadRequestException("Upsert tidak didukung tabel ini");
            const updates = keys.filter((key) => !conflictKeys.includes(key));
            conflict = ` ON CONFLICT (${conflictKeys.map((key) => this.ident(key)).join(", ")}) ${updates.length ? `DO UPDATE SET ${updates.map((key) => `${this.ident(key)} = EXCLUDED.${this.ident(key)}`).join(", ")}` : "DO NOTHING"}`;
          }
          const result = await tx.$queryRawUnsafe(`INSERT INTO public.${this.ident(table)} (${keys.map((key) => this.ident(key)).join(", ")}) VALUES (${placeholders})${conflict} RETURNING *`, ...params) as unknown[];
          inserted.push(...result);
        }
        return { data: Array.isArray(input) ? inserted : inserted[0] ?? null, error: null };
      }

      if (query.action === "update") {
        if (!filters.length) throw new BadRequestException("Perubahan wajib dibatasi dengan filter");
        const values = query.values as Record<string, unknown> | undefined;
        if (!values || Array.isArray(values) || !Object.keys(values).length) throw new BadRequestException("Perubahan kosong");
        const keys = Object.keys(values);
        keys.forEach((key) => this.checkColumn(columns, key));
        const params: unknown[] = keys.map((key) => values[key]);
        const assignments = keys.map((key, index) => `${this.ident(key)} = $${index + 1}`).join(", ");
        const where = this.whereClause(filters, params);
        const rows = await tx.$queryRawUnsafe(`UPDATE public.${this.ident(table)} SET ${assignments}${where} RETURNING *`, ...params) as unknown[];
        return { data: rows, error: null };
      }

      if (!filters.length) throw new BadRequestException("Penghapusan wajib dibatasi dengan filter");
      const params: unknown[] = [];
      const where = this.whereClause(filters, params);
      const rows = await tx.$queryRawUnsafe(`DELETE FROM public.${this.ident(table)}${where} RETURNING *`, ...params) as unknown[];
      return { data: rows, error: null };
    });
  }

  private whereClause(filters: NonNullable<DataQuery["filters"]>, values: unknown[]) {
    if (!filters.length) return "";
    return ` WHERE ${filters.map((filter) => {
      values.push(filter.value);
      return `${this.ident(filter.column)} ${filter.operator === "neq" ? "<>" : "="} $${values.length}`;
    }).join(" AND ")}`;
  }

  private checkColumn(allowed: Set<string>, value: string) {
    if (!IDENTIFIER.test(value) || !allowed.has(value)) throw new BadRequestException("Kolom tidak diizinkan");
  }

  private ident(value: string) {
    if (!IDENTIFIER.test(value)) throw new BadRequestException("Identifier tidak valid");
    return `"${value}"`;
  }

  private async withIdentity<T>(identity: AuthIdentity, work: (tx: any) => Promise<T>): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe("SET LOCAL ROLE authenticated");
      const claims = JSON.stringify({ sub: identity.id, role: "authenticated", aal: identity.aal });
      await tx.$queryRaw`SELECT set_config('request.jwt.claim.sub', ${identity.id}, true)`;
      await tx.$queryRaw`SELECT set_config('request.jwt.claims', ${claims}, true)`;
      return work(tx);
    });
  }
}
