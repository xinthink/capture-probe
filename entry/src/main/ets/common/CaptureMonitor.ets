/*
 * CaptureProbe - listener registration.
 *
 * display.on('captureStatusChange') is a device level signal: it becomes true
 * for screenshots, screen recording and casting, and it does not tell which one
 * happened. window.on('screenshot') is per-window and only fires for the focused
 * window. The probe logs both, plus optional extras that help judge timing:
 *   - window.on('screenshotAppEvent') (API 20+) which carries an event type
 *   - a display.isCaptured() sampler, to see when the state actually flips
 */

import { display, window } from '@kit.ArkUI';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import { EventKind, POLL_INTERVAL_MS, ProbeStore, readCaptured } from './ProbeStore';


export class CaptureMonitor {
  private static mainWindow: window.Window | null = null;
  private static pageWindow: window.Window | null = null;
  private static displayOn: boolean = false;
  private static shotOn: boolean = false;
  private static shotAppOn: boolean = false;
  private static pageOn: boolean = false;
  private static pollOn: boolean = false;
  private static pollTimer: number = -1;
  private static pollState: boolean = false;
  private static recorderConnection: number = -1;

  static getMainWindow(): window.Window | null {
    return CaptureMonitor.mainWindow;
  }

  /** Called from EntryAbility once the content is loaded: the recommended registration point. */
  static attachMain(win: window.Window): void {
    if (CaptureMonitor.mainWindow !== null) {
      return;
    }
    CaptureMonitor.mainWindow = win;
    ProbeStore.get().push(EventKind.INFO, 'monitor', 'attach', 'main window listener attached (EntryAbility)');
    CaptureMonitor.setDisplayListener(true);
    CaptureMonitor.setShotListener(true);
    CaptureMonitor.setShotAppListener(true);
    try {
      win.on('windowEvent', (event: window.WindowEventType) => {
        let name = 'WINDOW_EVENT_' + event.toString();
        if (event === window.WindowEventType.WINDOW_ACTIVE) {
          name = 'WINDOW_ACTIVE';
        } else if (event === window.WindowEventType.WINDOW_INACTIVE) {
          name = 'WINDOW_INACTIVE';
        } else if (event === window.WindowEventType.WINDOW_SHOWN) {
          name = 'WINDOW_SHOWN';
        } else if (event === window.WindowEventType.WINDOW_HIDDEN) {
          name = 'WINDOW_HIDDEN';
        }
        ProbeStore.get().push(EventKind.INFO, 'window', name, 'focus visibility change');
      });
    } catch (err) {
      ProbeStore.get().push(EventKind.INFO, 'window', 'error', 'windowEvent listener failed: ' + JSON.stringify(err));
    }
  }

  static setDisplayListener(on: boolean): void {
    if (on === CaptureMonitor.displayOn) {
      return;
    }
    try {
      if (on) {
        display.on('captureStatusChange', (captured: boolean) => {
          ProbeStore.get().push(EventKind.CAPTURE, 'display', captured ? 'true' : 'false',
            captured ? 'capture status -> true (screen is being captured)' : 'capture status -> false');
        });
        CaptureMonitor.displayOn = true;
      } else {
        display.off('captureStatusChange');
        CaptureMonitor.displayOn = false;
      }
      ProbeStore.get().push(EventKind.INFO, 'display', on ? 'on' : 'off', "display.on('captureStatusChange')");
    } catch (err) {
      ProbeStore.get().push(EventKind.INFO, 'display', 'error',
        "display.on('captureStatusChange') failed: " + JSON.stringify(err));
    }
  }

  static setShotListener(on: boolean): void {
    if (on === CaptureMonitor.shotOn || CaptureMonitor.mainWindow === null) {
      return;
    }
    try {
      if (on) {
        CaptureMonitor.mainWindow.on('screenshot', () => {
          ProbeStore.get().push(EventKind.SHOT, 'window', 'screenshot',
            "window.on('screenshot') fired (focused window)");
        });
        CaptureMonitor.shotOn = true;
      } else {
        CaptureMonitor.mainWindow.off('screenshot');
        CaptureMonitor.shotOn = false;
      }
      ProbeStore.get().push(EventKind.INFO, 'window', on ? 'on' : 'off', "window.on('screenshot')");
    } catch (err) {
      ProbeStore.get().push(EventKind.INFO, 'window', 'error',
        "window.on('screenshot') failed: " + JSON.stringify(err));
    }
  }

  static setShotAppListener(on: boolean): void {
    if (on === CaptureMonitor.shotAppOn || CaptureMonitor.mainWindow === null) {
      return;
    }
    try {
      if (on) {
        CaptureMonitor.mainWindow.on('screenshotAppEvent', (type: window.ScreenshotEventType) => {
          ProbeStore.get().push(EventKind.SHOT_APP, 'window', CaptureMonitor.shotAppName(type),
            "window.on('screenshotAppEvent') fired (API 20+)");
        });
        CaptureMonitor.shotAppOn = true;
      } else {
        CaptureMonitor.mainWindow.off('screenshotAppEvent');
        CaptureMonitor.shotAppOn = false;
      }
      ProbeStore.get().push(EventKind.INFO, 'window', on ? 'on' : 'off', "window.on('screenshotAppEvent')");
    } catch (err) {
      ProbeStore.get().push(EventKind.INFO, 'window', 'error',
        "window.on('screenshotAppEvent') failed: " + JSON.stringify(err));
    }
  }

  private static shotAppName(type: window.ScreenshotEventType): string {
    if (type === window.ScreenshotEventType.SYSTEM_SCREENSHOT) {
      return 'SYSTEM_SCREENSHOT';
    }
    if (type === window.ScreenshotEventType.SYSTEM_SCREENSHOT_ABORT) {
      return 'SYSTEM_SCREENSHOT_ABORT';
    }
    if (type === window.ScreenshotEventType.SCROLL_SHOT_START) {
      return 'SCROLL_SHOT_START';
    }
    if (type === window.ScreenshotEventType.SCROLL_SHOT_END) {
      return 'SCROLL_SHOT_END';
    }
    return 'SHOT_EVENT_' + type.toString();
  }

  /** Optional second listener on the same window, to check that duplicates are both delivered. */
  static setPageListener(on: boolean, win: window.Window | null): void {
    if (win === null || on === CaptureMonitor.pageOn) {
      return;
    }
    try {
      if (on) {
        win.on('screenshot', () => {
          ProbeStore.get().push(EventKind.SHOT, 'window(page)', 'screenshot', "page level window.on('screenshot')");
        });
        CaptureMonitor.pageWindow = win;
        CaptureMonitor.pageOn = true;
      } else {
        win.off('screenshot');
        CaptureMonitor.pageWindow = null;
        CaptureMonitor.pageOn = false;
      }
      ProbeStore.get().push(EventKind.INFO, 'window(page)', on ? 'on' : 'off', "extra page level listener");
    } catch (err) {
      ProbeStore.get().push(EventKind.INFO, 'window(page)', 'error',
        'page level listener failed: ' + JSON.stringify(err));
    }
  }

  static setPolling(on: boolean): void {
    if (on === CaptureMonitor.pollOn) {
      return;
    }
    CaptureMonitor.pollOn = on;
    if (on) {
      CaptureMonitor.pollState = readCaptured();
      CaptureMonitor.pollTimer = setInterval(() => {
        const current = readCaptured();
        if (current !== CaptureMonitor.pollState) {
          CaptureMonitor.pollState = current;
          ProbeStore.get().push(EventKind.SAMPLE, 'isCaptured', current ? 'true' : 'false',
            'sampler saw the flip (interval ' + POLL_INTERVAL_MS.toString() + 'ms)');
        }
      }, POLL_INTERVAL_MS);
    } else if (CaptureMonitor.pollTimer >= 0) {
      clearInterval(CaptureMonitor.pollTimer);
      CaptureMonitor.pollTimer = -1;
    }
    ProbeStore.get().push(EventKind.INFO, 'isCaptured', on ? 'on' : 'off',
      on ? 'isCaptured sampler started' : 'isCaptured sampler stopped');
  }

  /**
   * Diagnostic only: the control center screen recorder is a system
   * ServiceExtensionAbility that system UI binds to with this action. Binding to
   * it is the closest we can get to "start recording" from a normal app; the
   * system may reject the caller, in which case onFailed is reported.
   */
  static toggleRecorderService(context: common.UIAbilityContext): void {
    const store = ProbeStore.get();
    if (CaptureMonitor.recorderConnection >= 0) {
      const id = CaptureMonitor.recorderConnection;
      CaptureMonitor.recorderConnection = -1;
      context.disconnectServiceExtensionAbility(id).then((): void => {
        store.push(EventKind.INFO, 'recorder', 'disconnect', 'disconnect id=' + id.toString());
      }).catch((err: Error): void => {
        store.push(EventKind.INFO, 'recorder', 'disconnect error', err.message);
      });
      return;
    }

    const want: Want = {
      bundleName: 'com.huawei.hmos.screenrecorder',
      abilityName: 'com.huawei.hmos.screenrecorder.ServiceExtAbility',
      action: 'com.ohos.systemui.action.TOGGLE'
    };
    const options: common.ConnectOptions = {
      onConnect: (elementName: bundleManager.ElementName, remote: rpc.IRemoteObject): void => {
        store.push(EventKind.INFO, 'recorder', 'connected',
          elementName.bundleName + '/' + elementName.abilityName);
      },
      onDisconnect: (elementName: bundleManager.ElementName): void => {
        store.push(EventKind.INFO, 'recorder', 'disconnected', elementName.abilityName);
      },
      onFailed: (code: number): void => {
        store.push(EventKind.INFO, 'recorder', 'failed', 'connect failed, code=' + code.toString());
      }
    };
    try {
      CaptureMonitor.recorderConnection = context.connectServiceExtensionAbility(want, options);
      store.push(EventKind.INFO, 'recorder', 'connect',
        'connect requested, id=' + CaptureMonitor.recorderConnection.toString());
    } catch (err) {
      store.push(EventKind.INFO, 'recorder', 'connect error', JSON.stringify(err));
    }
  }
}
