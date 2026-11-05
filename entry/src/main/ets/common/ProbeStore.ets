/*
 * CaptureProbe - in-app event store and analyzer.
 *
 * Both EntryAbility (window listeners) and the page (UI) write into one
 * process-wide store, so the ordering of window.on('screenshot') and
 * display.on('captureStatusChange') is preserved in a single timeline.
 */

import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CaptureProbe';
const MAX_EVENTS = 400;

/** A screenshot event and a capture-state change inside this window are treated as one action. */
export const CORRELATION_MS = 2000;
/** Interval of the optional display.isCaptured() sampler. */
export const POLL_INTERVAL_MS = 100;

export enum EventKind {
  SHOT = 'SHOT',
  SHOT_APP = 'SHOT_APP',
  CAPTURE = 'CAPTURE',
  SAMPLE = 'SAMPLE',
  RECONCILE = 'RECONCILE',
  INFO = 'INFO'
}

export class ProbeEvent {
  id: number = 0;
  kind: EventKind = EventKind.INFO;
  source: string = '';
  flag: string = '';
  isCaptured: string = '?';
  time: number = 0;
  clock: string = '';
  delta: number = 0;
  note: string = '';
}

export class ProbeStats {
  shots: number = 0;
  shotsApp: number = 0;
  captureOn: number = 0;
  captureOff: number = 0;
  screenshotPulses: number = 0;
  recordingPulses: number = 0;
  lastShotToCapture: number = 0;
  hasShotDelta: boolean = false;
  lastPulseMs: number = 0;
  lastPulseKind: string = '-';
  lastVerdict: string = 'idle';
  lastVerdictDetail: string = 'no event yet';
  captureActive: boolean = false;
  activeSince: number = 0;
}

function pad(value: number, width: number): string {
  let text = value.toString();
  while (text.length < width) {
    text = '0' + text;
  }
  return text;
}

export function formatClock(time: number): string {
  const date = new Date(time);
  return pad(date.getHours(), 2) + ':' + pad(date.getMinutes(), 2) + ':' + pad(date.getSeconds(), 2) +
    '.' + pad(date.getMilliseconds(), 3);
}

/** display.isCaptured() never throws in practice, but keep the probe alive if it does. */
export function readCaptured(): boolean {
  try {
    return display.isCaptured();
  } catch (err) {
    return false;
  }
}

export class ProbeStore {
  private static instance: ProbeStore | null = null;

  events: ProbeEvent[] = [];
  stats: ProbeStats = new ProbeStats();
  version: number = 0;
  startedAt: number = Date.now();

  private listeners: Array<() => void> = [];
  private shotListeners: Array<(event: ProbeEvent) => void> = [];
  private seq: number = 0;
  private lastEventTime: number = 0;
  private lastShotTime: number = -1;
  private pendingCaptureId: number = -1;
  private pendingCaptureTime: number = 0;
  private pendingWasScreenshot: boolean = false;
  private sessionActive: boolean = false;
  /** True when the session was reconstructed from isCaptured(), so its start time is unknown. */
  private sessionApproximate: boolean = false;

  static get(): ProbeStore {
    if (ProbeStore.instance === null) {
      ProbeStore.instance = new ProbeStore();
    }
    return ProbeStore.instance;
  }

  push(kind: EventKind, source: string, flag: string, note: string): ProbeEvent {
    const event = new ProbeEvent();
    event.id = ++this.seq;
    event.kind = kind;
    event.source = source;
    event.flag = flag;
    event.note = note;
    event.time = Date.now();
    event.clock = formatClock(event.time);
    event.delta = this.lastEventTime === 0 ? 0 : event.time - this.lastEventTime;
    event.isCaptured = readCaptured() ? 'true' : 'false';
    this.lastEventTime = event.time;

    this.analyze(event);

    this.events.push(event);
    if (this.events.length > MAX_EVENTS) {
      this.events.splice(0, this.events.length - MAX_EVENTS);
    }
    this.version++;
    hilog.info(DOMAIN, TAG, '%{public}s', event.clock + ' | ' + kind + ' | ' + source + ' | ' + flag +
      ' | isCaptured=' + event.isCaptured + ' | delta=' + event.delta.toString() + 'ms | ' + event.note);
    this.notify();
    return event;
  }

  /** Classification is done when the event arrives, so the log keeps raw order and raw timings. */
  private analyze(event: ProbeEvent): void {
    if (event.kind === EventKind.SHOT || event.kind === EventKind.SHOT_APP) {
      if (event.kind === EventKind.SHOT) {
        this.stats.shots++;
        let consumed = false;
        if (this.pendingCaptureId >= 0 && !this.pendingWasScreenshot &&
          event.time - this.pendingCaptureTime <= CORRELATION_MS) {
          // Screenshot callback arrived after capture went true: correct the verdict.
          const delta = event.time - this.pendingCaptureTime;
          this.stats.lastVerdict = 'SCREENSHOT';
          this.stats.lastVerdictDetail = this.sessionActive ?
            'screenshot during an active recording/cast (window event +' + delta.toString() + 'ms late)' :
            'window screenshot arrived ' + delta.toString() + 'ms AFTER capture=true';
          this.stats.lastShotToCapture = delta;
          this.stats.hasShotDelta = true;
          this.stats.screenshotPulses++;
          this.pendingWasScreenshot = true;
          consumed = true;
          event.note = event.note + ' -> reclassifies capture #' + this.pendingCaptureId.toString() +
            ' as SCREENSHOT (shot is +' + delta.toString() + 'ms late)' +
            (this.sessionActive ? ', session continues' : '');
        } else if (this.sessionActive) {
          this.stats.lastVerdict = 'SCREENSHOT';
          this.stats.lastVerdictDetail = 'screenshot during an active recording/cast';
          this.stats.screenshotPulses++;
        }
        this.lastShotTime = consumed ? -1 : event.time;
      } else {
        this.stats.shotsApp++;
      }
      for (const listener of this.shotListeners) {
        listener(event);
      }
      return;
    }

    if (event.kind === EventKind.CAPTURE && event.flag === 'true') {
      this.stats.captureOn++;
      this.pendingCaptureId = event.id;
      this.pendingCaptureTime = event.time;
      this.pendingWasScreenshot = false;

      // isCaptured() is true for a sustained session (recording / cast / WebRTC
      // screen share) and false for a one-shot screenshot. That is the reliable
      // discriminator; event ordering is not.
      if (event.isCaptured === 'true') {
        if (!this.sessionActive) {
          this.sessionActive = true;
          this.sessionApproximate = false;
          this.stats.captureActive = true;
          this.stats.activeSince = event.time;
          this.stats.lastVerdict = 'RECORDING / CAST';
          this.stats.lastVerdictDetail = 'sustained capture started (isCaptured=true in the callback)';
          event.note = event.note + ' | verdict=RECORDING|CAST (sustained, isCaptured=true)';
        } else {
          this.stats.lastVerdict = 'RECORDING / CAST';
          this.stats.lastVerdictDetail = 'a capture started while the session is already running (likely a screenshot)';
          event.note = event.note + ' | capture start while already captured (session continues)';
        }
        return;
      }

      // isCaptured=false: transient capture, i.e. a screenshot on this build.
      if (this.lastShotTime > 0) {
        const delta = event.time - this.lastShotTime;
        if (Math.abs(delta) <= CORRELATION_MS) {
          this.pendingWasScreenshot = true;
          this.stats.lastVerdict = 'SCREENSHOT';
          this.stats.lastVerdictDetail = 'capture=true ' + (delta >= 0 ? delta.toString() + 'ms after' :
            (-delta).toString() + 'ms before') + ' window screenshot event';
          this.stats.lastShotToCapture = delta;
          this.stats.hasShotDelta = true;
          this.stats.screenshotPulses++;
          event.note = event.note + ' | verdict=SCREENSHOT (delta=' + delta.toString() + 'ms)';
          this.lastShotTime = -1; // consume, one screenshot explains one capture pulse
        } else {
          this.stats.hasShotDelta = false;
          this.stats.lastVerdict = 'SCREENSHOT (likely)';
          this.stats.lastVerdictDetail = 'transient capture (isCaptured=false) without a fresh window screenshot event';
          event.note = event.note + ' | verdict=SCREENSHOT? (transient, last shot ' + delta.toString() + 'ms ago)';
        }
      } else {
        this.stats.hasShotDelta = false;
        this.stats.lastVerdict = 'SCREENSHOT (likely)';
        this.stats.lastVerdictDetail = 'transient capture (isCaptured=false); no window screenshot event (app not focused?)';
        event.note = event.note + ' | verdict=SCREENSHOT? (transient, no window screenshot event)';
      }
      return;
    }

    if (event.kind === EventKind.CAPTURE && event.flag === 'false') {
      this.stats.captureOff++;
      if (this.sessionActive) {
        const pulse = this.stats.activeSince === 0 ? 0 : event.time - this.stats.activeSince;
        this.stats.lastPulseMs = pulse;
        this.stats.lastPulseKind = 'RECORDING / CAST';
        this.stats.recordingPulses++;
        this.stats.lastVerdict = 'RECORDING / CAST';
        this.stats.lastVerdictDetail = 'session ended after ' + pulse.toString() + 'ms' +
          (this.sessionApproximate ? ' (start missed while backgrounded; timing from resume)' : '');
        event.note = event.note + ' | session end, pulse=' + pulse.toString() + 'ms (recording|cast)' +
          (this.sessionApproximate ? ', start missed' : '');
        this.sessionActive = false;
        this.sessionApproximate = false;
        this.stats.captureActive = false;
        this.stats.activeSince = 0;
      } else if (this.pendingWasScreenshot) {
        const pulse = event.time - this.pendingCaptureTime;
        this.stats.lastPulseMs = pulse;
        this.stats.lastPulseKind = 'SCREENSHOT';
        event.note = event.note + ' | screenshot pulse=' + pulse.toString() + 'ms';
      } else {
        event.note = event.note + ' | capture=false without an active session';
      }
      this.pendingCaptureId = -1;
      this.pendingWasScreenshot = false;
      return;
    }
  }

  /**
   * While the process is frozen in background, capture=true/false can be lost
   * (report sections 10.7-10.8). isCaptured() is a query and stays truthful after
   * resume, so compare it with the event-driven session on every foreground
   * transition and repair the difference.
   */
  reconcile(trigger: string): void {
    const actual = readCaptured();
    if (actual === this.sessionActive) {
      return;
    }
    const now = Date.now();
    if (this.sessionActive) {
      // The session ended while the process was frozen: capture=false was lost.
      const elapsed = this.stats.activeSince === 0 ? 0 : now - this.stats.activeSince;
      this.sessionActive = false;
      this.sessionApproximate = false;
      this.stats.captureActive = false;
      this.stats.activeSince = 0;
      this.stats.recordingPulses++;
      this.stats.lastPulseMs = elapsed;
      this.stats.lastPulseKind = 'RECORDING / CAST';
      this.stats.lastVerdict = 'RECORDING / CAST';
      this.stats.lastVerdictDetail = 'ended while backgrounded: capture=false was lost; duration unknown (<= ' +
        elapsed.toString() + 'ms)';
      this.push(EventKind.RECONCILE, 'reconcile', 'session lost end',
        'isCaptured=false on ' + trigger + ', but capture=false never arrived -> session closed (upper bound ' +
        elapsed.toString() + 'ms)');
      return;
    }
    // The session started while the process was frozen: capture=true was lost.
    this.sessionActive = true;
    this.sessionApproximate = true;
    this.stats.captureActive = true;
    this.stats.activeSince = now;
    this.stats.lastVerdict = 'RECORDING / CAST';
    this.stats.lastVerdictDetail = 'started while backgrounded: capture=true was lost; timing starts at ' + trigger;
    this.push(EventKind.RECONCILE, 'reconcile', 'session lost start',
      'isCaptured=true on ' + trigger + ', but capture=true never arrived -> session opened at resume');
  }

  subscribe(listener: () => void): void {
    this.listeners.push(listener);
  }

  unsubscribe(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  onShot(listener: (event: ProbeEvent) => void): void {
    this.shotListeners.push(listener);
  }

  reset(): void {
    this.events = [];
    this.stats = new ProbeStats();
    this.lastEventTime = 0;
    this.lastShotTime = -1;
    this.pendingCaptureId = -1;
    this.pendingWasScreenshot = false;
    this.sessionActive = false;
    this.sessionApproximate = false;
    this.version++;
    this.notify();
  }

  /** Plain-text dump, used by the "copy log" button. */
  toText(): string {
    const lines: Array<string> = [];
    lines.push('# CaptureProbe log');
    lines.push('startedAt=' + formatClock(this.startedAt) + ' api=' + this.apiNote);
    lines.push('shots=' + this.stats.shots.toString() + ' shotsApp=' + this.stats.shotsApp.toString() +
      ' captureOn=' + this.stats.captureOn.toString() + ' captureOff=' + this.stats.captureOff.toString() +
      ' screenshotPulses=' + this.stats.screenshotPulses.toString() +
      ' recordingPulses=' + this.stats.recordingPulses.toString());
    for (const event of this.events) {
      lines.push(event.clock + '  ' + event.kind.padEnd(8, ' ') + '  ' + event.flag.padEnd(18, ' ') +
        '  delta=' + event.delta.toString().padStart(6, ' ') + 'ms  isCaptured=' + event.isCaptured +
        '  ' + event.source + '  ' + event.note);
    }
    return lines.join('\n');
  }

  apiNote: string = 'unknown';

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
  }
}
