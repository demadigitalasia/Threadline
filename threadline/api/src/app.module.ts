import { Module } from "@nestjs/common";
import { AuthController } from "./auth/auth.controller";
import { AuthService } from "./auth/auth.service";
import { AdminController } from "./admin/admin.controller";
import { DataController } from "./data/data.controller";
import { DataService } from "./data/data.service";
import { RpcController } from "./data/rpc.controller";
import { HealthController } from "./health.controller";
import { PrismaService } from "./prisma/prisma.service";
import { RealtimeController } from "./realtime/realtime.controller";
import { StorageController } from "./storage/storage.controller";
import { StorageService } from "./storage/storage.service";
import { BootstrapService } from "./bootstrap.service";

@Module({
  controllers: [AuthController, AdminController, DataController, RpcController, StorageController, RealtimeController, HealthController],
  providers: [PrismaService, AuthService, DataService, StorageService, BootstrapService],
})
export class AppModule {}
