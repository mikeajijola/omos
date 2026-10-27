// Drive the existing native UI protocol inside a worker. Public activity is
// retained in bounded batches; provider replay and reasoning never leave it.
import { createHash, randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";

const fail = code => { throw new Error(code); };
const maximumLine = 12 * 1024 * 1024;
const maximumActivityEvents = 8;
const maximumActivityRequest = 128 * 1024;
function bounded(text, limit = 8192) {
  if (typeof text !== "string") return "";
  let result = "", bytes = 0;
  for (const point of text) {
    const size = Buffer.byteLength(point);
    if (bytes + size > limit) break;
    result += point; bytes += size;
  }
  return result;
}
function* textParts(text) {
  let part = "", bytes = 0;
  for (const point of text) {
    const size = Buffer.byteLength(point);
    if (bytes + size > 2048) { yield part; part = ""; bytes = 0; }
    part += point; bytes += size;
  }
  if (part) yield part;
}
export function publicWorkerEvents(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) fail("InvalidWorkerNativeEvent");
  const type = data.type;
  if (["assistant_started", "assistant_restarted", "turn_start"].includes(type)) return [{ type }];
  if (["text_delta", "command_output"].includes(type)) {
    if (typeof data.text !== "string") fail("InvalidWorkerNativeEvent");
    return Array.from(textParts(data.text), text => type === "text_delta" ? { type, text } : { type, call_id: data.call_id ?? null, stream: data.stream, text });
  }
  if (["notice", "tool_progress"].includes(type)) return [{ type, ...(type === "tool_progress" ? { call_id: data.call_id } : {}), text: bounded(data.text) }];
  if (type === "tool_start") return [{ type, call_id: data.call_id, name: data.name, path: data.path ?? null, action: data.action ?? null }];
  if (type === "tool_end") return [{ type, call_id: data.call_id, outcome: typeof data.outcome === "string" ? data.outcome : data.outcome?.kind ?? "completed", text: bounded(data.outcome?.summary) }];
  if (type === "input_required") return [{ type, kind: data.kind, request_id: data.request_id, ...(data.kind === "approval" ? { prompt: data.prompt } : { questions: (data.questions ?? []).map(question => ({ question: question.question, options: (question.options ?? []).map(option => ({ label: option.label, ...(option.description ? { description: option.description } : {}) })) })) }) }];
  if (type === "error") return [{ type, code: /^[A-Z][A-Za-z0-9]{0,95}$/.test(data.code) ? data.code : "WorkerNativeInvocationFailed" }];
  if (type === "result" && typeof data.data?.error === "string") return [{ type: "error", code: /^[A-Z][A-Za-z0-9]{0,95}$/.test(data.data.error) ? data.data.error : "WorkerNativeInvocationFailed" }];
  if (type === "turn_end") return [{ type, exit_code: data.exit_code }];
  // Session identities, result metadata, private provider data and unsupported
  // events are not copied into company activity. Final text is handled below.
  return [];
}

export async function runWorkerNative({ launch, control, view, execution, prompt, session, replayOnly = false, inputControl, signal, timeout = 240000 }) {
  if (typeof launch !== "function" || typeof control?.call !== "function" || typeof prompt !== "string" || Buffer.byteLength(prompt) > 131072 || typeof replayOnly !== "boolean" || (replayOnly && (typeof session !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(session))) || !Number.isSafeInteger(timeout) || timeout < 1 || timeout > 300000) fail("InvalidWorkerNativeInvocation");
  signal?.throwIfAborted();
  const before = await control.call({ action: "inspect", view, execution }, signal);
  if (!before.ok || before.next_offset !== 0 || before.ended) fail("WorkerNativeActivityAlreadyStarted");
  const child = await launch();
  let offset = 0, nativeCursor = 0, nextId = 0, failure, exitCode, killed = false, force, timer, flushTimer;
  let textHash = createHash("sha256"), textBytes = 0, buffered = "", errorBytes = 0;
  const errors = [], pending = new Map(), queue = [];
  const turn = randomUUID();
  let uploads = Promise.resolve();
  let inputTimer, inputPoll = Promise.resolve(), waitingInput = false, ending = false;
  const stop = () => {
    if (killed) return;
    killed = true;
    child.stdin.destroy();
    child.kill("SIGTERM");
    force = setTimeout(() => { child.kill("SIGKILL"); child.stdout.destroy(); child.stderr.destroy(); }, 10000);
  };
  const rejectPending = () => {
    for (const waiting of pending.values()) waiting.reject(new Error("WorkerNativeInvocationStopped"));
    pending.clear();
  };
  const closed = new Promise((resolve, reject) => {
    child.once("error", error => { rejectPending(); reject(error); });
    child.once("exit", (code, stoppedBy) => {
      if (!killed) return;
      // On failure, wait for the owned process, rather than an open writable
      // stream in the Node/Bun compatibility layer. No successful result can
      // be accepted after stop(), and the private task remains retained.
      child.stdout.destroy(); child.stderr.destroy(); rejectPending();
      resolve({ code, stoppedBy });
    });
    child.once("close", (code, stoppedBy) => { rejectPending(); resolve({ code, stoppedBy }); });
  });
  closed.catch(() => {});
  child.stdin.on("error", () => {});
  child.stderr.on("data", chunk => { errorBytes += chunk.length; if (errorBytes <= 65536) errors.push(chunk); });
  signal?.addEventListener("abort", stop, { once: true });
  if (signal?.aborted) stop();
  timer = setTimeout(stop, timeout);
  const request = (method, params, id = "command-" + (++nextId)) => new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ version: "omos.ui-host/v1", id, method, params }) + "\n");
  });
  const flush = () => {
    clearTimeout(flushTimer); flushTimer = undefined;
    if (!queue.length) return uploads;
    const waiting = queue.splice(0);
    uploads = uploads.then(async () => {
      while (waiting.length) {
        const events = waiting.slice(0, maximumActivityEvents);
        const mutation = { action: "append", view, execution, offset, events };
        // Events are JSON strings inside the request. Bound their encoded size,
        // including escaping, rather than just summing the source event bytes.
        while (Buffer.byteLength(JSON.stringify(mutation)) > maximumActivityRequest && events.length > 1) events.pop();
        if (Buffer.byteLength(JSON.stringify(mutation)) > maximumActivityRequest) fail("WorkerNativeActivityEventTooLarge");
        let saved = await control.call(mutation, signal);
        // Native offsets and exact immutable payloads make this one explicit
        // metadata retry safe. It cannot restart an actor or execute a tool.
        if (!saved.ok) saved = await control.call(mutation, signal);
        if (!saved.ok || saved.next_offset !== offset + events.length) throw Object.assign(Error("WorkerActivityRetentionPending"), { retention: { kind: "activity", action: "append", offset, error: typeof saved.error === "string" && /^[A-Z][A-Za-z0-9_]{0,95}$/.test(saved.error) ? saved.error : saved.ok ? "WorkerActivityPositionChanged" : "Unknown", ...(typeof saved.transport === "string" && /^[A-Za-z][A-Za-z0-9_]{0,95}$/.test(saved.transport) ? { transport: saved.transport } : {}) } });
        offset = saved.next_offset;
        waiting.splice(0, events.length);
      }
    });
    uploads.catch(error => { failure ??= error; stop(); });
    return uploads;
  };
  const emit = async data => {
    const raw = JSON.stringify(data);
    if (Buffer.byteLength(raw) > 16384) fail("WorkerNativeActivityEventTooLarge");
    queue.push(raw);
    if (queue.length >= maximumActivityEvents) await flush();
    else if (!flushTimer) flushTimer = setTimeout(() => { void flush(); }, 100);
  };
  const emitPublic = async data => {
    if (["assistant_started", "assistant_restarted"].includes(data.type)) { textHash = createHash("sha256"); textBytes = 0; }
    if (data.type === "text_delta") { textHash.update(data.text); textBytes += Buffer.byteLength(data.text); }
    if (data.type === "result") {
      const text = data.data?.final_output;
      if (typeof text === "string" && text.length && (Buffer.byteLength(text) !== textBytes || createHash("sha256").update(text).digest("hex") !== textHash.copy().digest("hex"))) {
        await emit({ type: "assistant_restarted" });
        for (const part of textParts(text)) await emit({ type: "text_delta", text: part });
      }
    }
    if (data.type === "validate_ui") await emit({ type: "notice", text: "The retained private task is waiting for a configured UI validator." });
    for (const selected of publicWorkerEvents(data)) await emit(selected);
  };
  const pollInput = () => {
    clearTimeout(inputTimer);
    if (!inputControl || ending || killed || !waitingInput) return;
    inputPoll = (async () => {
      const found = await inputControl.call({ action: "inspect", view, execution }, signal);
      if (!found.ok) fail("WorkerInputControlUnavailable");
      for (const command of found.commands) {
        if (command.state !== "pending") fail("WorkerInputOutcomeUncertain");
        const delivery = randomUUID();
        const claim = { action: "claim", view, execution, event_offset: command.command.event_offset, delivery };
        let owned = await inputControl.call(claim, signal);
        if (!owned.ok) owned = await inputControl.call(claim, signal);
        if (!owned.ok || owned.commands.length !== 1 || owned.commands[0].delivery !== delivery || owned.commands[0].state !== "dispatching") fail("WorkerInputOutcomeUncertain");
        let outcome = "applied";
        try {
          await request("input", { turn, request_id: command.command.request_id, ...(command.command.approved !== null ? { approved: command.command.approved } : { answers: command.command.answers }) });
        } catch (error) {
          if (error.message !== "WorkerNativeRequestRejected" || !["NoActiveInput", "InvalidQuestionAnswers", "StaleInputRequest", "StaleTurn", "NoActiveTurn"].includes(error.nativeCode)) fail("WorkerInputOutcomeUncertain");
          outcome = "failed";
        }
        const acknowledge = { action: "acknowledge", view, execution, event_offset: command.command.event_offset, delivery, outcome };
        let saved = await inputControl.call(acknowledge, signal);
        if (!saved.ok) saved = await inputControl.call(acknowledge, signal);
        if (!saved.ok || saved.commands[0]?.state !== outcome) fail("WorkerInputOutcomeUncertain");
        if (outcome === "failed") fail("WorkerInputRejected");
        waitingInput = false;
      }
    })();
    inputPoll.then(() => { if (!ending && !killed && waitingInput) inputTimer = setTimeout(pollInput, 1000); }, error => { failure ??= error; stop(); });
  };
  try {
    const initialized = request("initialize", {});
    let started;
    // Keep stdin open through turn_end. EOF deliberately cancels a native UI
    // job and would otherwise turn every request into an interrupted turn.
    const consume = (async () => {
      const decoder = new StringDecoder("utf8");
      for await (const chunk of child.stdout) {
        buffered += decoder.write(chunk);
        if (Buffer.byteLength(buffered) > maximumLine) fail("WorkerNativeLineTooLarge");
        let end;
        while ((end = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
          if (!line.trim()) continue;
          const event = JSON.parse(line);
          if (event.version !== "omos.ui-host/v1") fail("InvalidWorkerNativeEvent");
          if (event.type === "response") {
            const waiting = pending.get(event.id);
            if (!waiting) fail("InvalidWorkerNativeResponse");
            pending.delete(event.id);
            if (event.err) waiting.reject(Object.assign(new Error("WorkerNativeRequestRejected"), { nativeCode: typeof event.err === "string" && /^[A-Z][A-Za-z0-9]{0,95}$/.test(event.err) ? event.err : "UnknownNativeFailure" })); else waiting.resolve(event.result);
            continue;
          }
          if (event.type !== "event" || event.turn !== turn || event.cursor !== nativeCursor + 1) fail("InvalidWorkerNativeEvent");
          nativeCursor = event.cursor;
          const data = event.data;
          await emitPublic(data);
          if (data.type === "input_required" && inputControl) {
            await flush(); await uploads;
            waitingInput = true;
            pollInput();
          }
          if (data.type === "turn_end") {
            ending = true;
            clearTimeout(inputTimer);
            exitCode = data.exit_code;
            await flush(); await uploads;
            child.stdin.end();
          }
        }
      }
      buffered += decoder.end();
    })();
    consume.catch(error => { failure ??= error; stop(); });
    await initialized;
    if (replayOnly) {
      let offset = 0, savedTurn, finished = false;
      // The image is quiescent. Read the last recorded episode without starting
      // a prompt or answering any retained input request.
      while (!killed) {
        signal?.throwIfAborted();
        const page = await request("session.events", { session, offset });
        if (page.active !== false || !Array.isArray(page.events) || page.events.length > 32 || !Number.isSafeInteger(page.next_offset) || page.next_offset < offset || (page.events.length && page.next_offset === offset)) fail("WorkerNativeHistoryChanged");
        for (const event of page.events) {
          if (event.version !== "omos.ui-host/v1" || event.type !== "event" || typeof event.turn !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(event.turn) || (savedTurn && event.turn !== savedTurn) || event.cursor !== nativeCursor + 1 || exitCode !== undefined) fail("WorkerNativeHistoryChanged");
          savedTurn = event.turn; nativeCursor = event.cursor;
          if (event.data?.type === "input_required") {
            const text = event.data.kind === "approval" ? event.data.prompt : (event.data.questions ?? []).map(question => question.question).join("; ");
            await emit({ type: "notice", text: "Saved input from the previous invocation: " + bounded(text, 8000) });
          } else await emitPublic(event.data);
          if (event.data.type === "turn_end") exitCode = event.data.exit_code;
        }
        if (page.events.length < 32 || page.next_offset === offset) { finished = true; break; }
        offset = page.next_offset;
      }
      if (!finished || !Number.isInteger(exitCode) || exitCode < 0 || exitCode > 255) fail("WorkerNativeHistoryIncomplete");
      ending = true;
      await flush(); await uploads;
      child.stdin.end();
    } else {
      started = request("prompt", { text: prompt, ...(session ? { session } : {}) }, turn);
      await started;
    }
    const result = await closed;
    await consume;
    ending = true; clearTimeout(inputTimer);
    await inputPoll;
    await flush(); await uploads;
    if (failure) throw failure;
    if (buffered.trim() || !Number.isInteger(exitCode) || exitCode < 0 || exitCode > 255 || result.code !== 0 || result.stoppedBy) fail("WorkerNativeInvocationStopped");
    return { code: exitCode, killed, stdout: "", stderr: Buffer.concat(errors).toString("utf8"), output_complete: errorBytes <= 65536 };
  } catch (error) {
    stop();
    await closed.catch(() => {});
    // Killing the owned child can close its readable stream before the main
    // consumer joins. Preserve the retention failure that initiated cleanup.
    throw failure ?? error;
  } finally {
    ending = true;
    clearTimeout(timer); clearTimeout(force); clearTimeout(flushTimer); clearTimeout(inputTimer);
    await inputPoll.catch(() => {});
    signal?.removeEventListener("abort", stop);
    rejectPending();
  }
}
