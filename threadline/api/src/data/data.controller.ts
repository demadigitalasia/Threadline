import { Body, Controller, Param, Post, Req } from "@nestjs/common";
import type { Request } from "express";
import { AuthService } from "../auth/auth.service";
import { DataService, type DataQuery } from "./data.service";

@Controller("data")
export class DataController {
  constructor(private readonly auth: AuthService, private readonly data: DataService) {}

  @Post(":table")
  async execute(@Req() req: Request, @Param("table") table: string, @Body() body: DataQuery) {
    const identity = await this.auth.resolve(req.headers.cookie);
    if (!identity) return { data: null, error: { message: "Sesi tidak valid" } };
    return this.data.execute(identity, table, body);
  }
}
