import { Body, Controller, Get, Post, Req, Res } from "@nestjs/common";
import type { Request, Response } from "express";
import { AuthService } from "./auth.service";

@Controller("auth")
export class AuthController {
  constructor(private readonly auth: AuthService) {}
  private secure(req: Request) { return process.env.NODE_ENV === "production" || req.secure; }
  private frontendUrl() { return process.env.FRONTEND_URL ?? "http://localhost:3000"; }

  @Get("session")
  async session(@Req() req: Request) {
    const [user, identity] = await Promise.all([this.auth.user(req.headers.cookie), this.auth.resolve(req.headers.cookie)]);
    return { user, session: identity ? { user, assuranceLevel: identity.aal } : null };
  }

  @Post("sign-in")
  async signIn(@Req() req: Request, @Res({ passthrough: true }) res: Response, @Body() body: { email: string; password: string }) {
    const result = await this.auth.signIn(body.email, body.password);
    res.setHeader("Set-Cookie", this.auth.setSessionCookie(result.token, this.secure(req)));
    return { user: result.user };
  }

  @Post("sign-out")
  async signOut(@Req() req: Request, @Res({ passthrough: true }) res: Response) {
    await this.auth.signOut(req.headers.cookie);
    res.setHeader("Set-Cookie", this.auth.clearSessionCookie(this.secure(req)));
    return { signedOut: true };
  }

  @Post("sign-up")
  signUp(@Body() body: { email: string; password: string; data?: { name?: string; whatsapp?: string } }) {
    return this.auth.signUp(body.email, body.password, body.data ?? {});
  }

  @Post("reset-password")
  requestPasswordReset(@Body() body: { email: string }) {
    return this.auth.requestPasswordReset(body.email, this.frontendUrl());
  }

  @Post("update-password")
  updatePassword(@Req() req: Request, @Body() body: { password: string }) {
    return this.auth.updatePassword(req.headers.cookie, body.password);
  }

  @Post("exchange-code")
  async exchangeCode(@Req() req: Request, @Res({ passthrough: true }) res: Response, @Body() body: { code: string }) {
    const result = await this.auth.exchangeCode(body.code);
    res.setHeader("Set-Cookie", this.auth.setSessionCookie(result.token, this.secure(req)));
    return { user: result.user, purpose: result.purpose };
  }

  @Post("resend-verification")
  resendVerification(@Body() body: { email: string }) {
    return this.auth.resendVerification(body.email, this.frontendUrl());
  }

  @Post("mfa/enroll")
  beginMfaEnrollment(@Body() body: { email: string; password: string }) {
    return this.auth.beginMfaEnrollment(body.email, body.password);
  }

  @Post("mfa/confirm")
  async confirmMfaEnrollment(@Req() req: Request, @Res({ passthrough: true }) res: Response, @Body() body: { email: string; password: string; code: string }) {
    const result = await this.auth.confirmMfaEnrollment(body.email, body.password, body.code);
    res.setHeader("Set-Cookie", this.auth.setSessionCookie(result.token, this.secure(req)));
    return { user: result.user };
  }
}
