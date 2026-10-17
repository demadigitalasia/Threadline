import { Controller, MessageEvent, Req, Sse, UnauthorizedException } from "@nestjs/common";
import type { Request } from "express";
import { interval, map, Observable, startWith } from "rxjs";
import { AuthService } from "../auth/auth.service";

@Controller("realtime")
export class RealtimeController {
  constructor(private readonly auth: AuthService) {}

  @Sse("events")
  async events(@Req() req: Request): Promise<Observable<MessageEvent>> {
    if (!(await this.auth.resolve(req.headers.cookie))) throw new UnauthorizedException("Sesi tidak valid");
    // The UI currently reloads a compact snapshot on database change events.
    // A heartbeat invalidation keeps that contract without exposing Postgres or R2 credentials.
    return interval(15_000).pipe(
      startWith(0),
      map(() => ({ data: { type: "invalidate", at: new Date().toISOString() } })),
    );
  }
}
