import { Body, Controller, Delete, Param, Post, Req, UnauthorizedException } from "@nestjs/common";
import type { Request } from "express";
import { AuthService } from "../auth/auth.service";
import { StorageService } from "./storage.service";

@Controller("storage")
export class StorageController {
  constructor(private readonly auth: AuthService, private readonly storage: StorageService) {}
  private async identity(req: Request) {
    const identity = await this.auth.resolve(req.headers.cookie);
    if (!identity) throw new UnauthorizedException("Sesi tidak valid");
    return identity;
  }
  @Post("upload-url")
  async uploadUrl(@Req() req: Request, @Body() body: { bucket: string; path: string; size: number; contentType?: string }) {
    return this.storage.createUploadUrl(await this.identity(req), body);
  }
  @Post("complete-upload")
  async completeUpload(@Req() req: Request, @Body() body: { intentId: string }) {
    return this.storage.completeUpload(await this.identity(req), body);
  }
  @Post(":bucket/signed-url")
  async signedUrl(@Req() req: Request, @Param("bucket") bucket: string, @Body() body: { path: string }) {
    return this.storage.signedUrl(await this.identity(req), bucket, body.path);
  }
  @Delete(":bucket")
  async remove(@Req() req: Request, @Param("bucket") bucket: string, @Body() body: { paths: string[] }) {
    return this.storage.remove(await this.identity(req), bucket, body.paths ?? []);
  }
}
