#!/usr/bin/env node
import { parseArgs } from "node:util";
import {
  loadBackupConfiguration,
  createBackupController,
} from "./backup-runtime.mjs";

const cancellation = new AbortController();
const cancel = () => cancellation.abort();
process.once("SIGINT", cancel);
process.once("SIGTERM", cancel);
let controller, action, operation;
try {
  const parsed = parseArgs({
    allowPositionals: true,
    options: {
      config: { type: "string" },
      operation: { type: "string" },
      snapshot: { type: "string" },
      directory: { type: "string" },
      help: { type: "boolean" },
    },
  });
  if (parsed.values.help) {
    console.log(
      "Usage: node backup.mjs initialize|create|inspect|restore --config PATH [--operation ID] [--snapshot SHA256] [--directory PATH]",
    );
  } else {
    action = parsed.positionals[0];
    operation = parsed.values.operation;
    if (
      parsed.positionals.length !== 1 ||
      !["initialize", "create", "inspect", "restore"].includes(action) ||
      !parsed.values.config ||
      (action === "create" && !operation) ||
      (["inspect", "restore"].includes(action) && !parsed.values.snapshot) ||
      (action === "restore" && !parsed.values.directory) ||
      (action !== "create" && operation) ||
      (!["inspect", "restore"].includes(action) && parsed.values.snapshot) ||
      (action !== "restore" && parsed.values.directory)
    )
      throw Object.assign(new Error("InvalidBackupArguments"), {
        code: "InvalidBackupArguments",
      });
    const config = await loadBackupConfiguration(parsed.values.config, {
      requireSource: action === "create",
    });
    controller = createBackupController(config, {
      signal: cancellation.signal,
    });
    const result = await controller.withLock(() => {
      switch (action) {
        case "initialize":
          return controller.initialize();
        case "create":
          return controller.create({ operation });
        case "inspect":
          return controller.inspect(parsed.values.snapshot);
        case "restore":
          return controller.restore({
            snapshot: parsed.values.snapshot,
            directory: parsed.values.directory,
          });
      }
    });
    console.log(JSON.stringify(result));
  }
} catch (error) {
  console.error(
    JSON.stringify({
      version: "omos.company-backup-error/v1",
      error: error.code ?? "BackupFailed",
      action,
      operation,
      outcome: error.outcome,
      stage: error.stage,
      exit_code: error.exit_code,
    }),
  );
  process.exitCode = 1;
} finally {
  controller?.close();
  process.removeListener("SIGINT", cancel);
  process.removeListener("SIGTERM", cancel);
}
