/*
 * CaptureProbe - screenshot vs screen recording probe UI.
 *
 * Everything shown here is driven by real system callbacks; nothing is simulated.
 * The top half tells the current capture state and the last verdict, the bottom
 * half is the raw event timeline so ordering can be inspected directly.
 */

import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CaptureMonitor } from '../common/CaptureMonitor';
import { CORRELATION_MS, EventKind, formatClock, ProbeEvent, ProbeStore, readCaptured } from '../common/ProbeStore';

const DOMAIN = 0x0000;
const TAG = 'CaptureProbe';

/*
 * Small child components instead of @Builder methods: @Builder parameters are
 * passed by value and do not refresh when the parent state changes, which made
 * the counters stay at 0 while the timeline was updating.
 */
@Component
struct CounterChip {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop color: string = '#1A1A1A';

  build() {
    Row() {
      Text(this.label)
        .fontSize(9)
        .fontColor('#8C8C8C')
        .margin({ right: 3 })
      Text(this.value.toString())
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
    }
    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
    .margin({ right: 6, top: 4 })
    .borderRadius(7)
    .backgroundColor(Color.White)
  }
}

@Component
struct SwitchRow {
  @Prop label: string = '';
  @Prop isOn: boolean = false;
  onChange: (value: boolean) => void = (value: boolean): void => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(11)
        .fontColor('#1A1A1A')
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor('#0A59F7')
        .width(34)
        .height(18)
        .onChange((value: boolean): void => {
          this.onChange(value);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 6, top: 2, bottom: 2 })
    .margin({ right: 8, bottom: 6 })
    .borderRadius(10)
    .backgroundColor(Color.White)
    .layoutWeight(1)
  }
}

@Entry
@Component
struct Index {
  @State events: ProbeEvent[] = [];
  @State captured: boolean = false;
  @State nowText: string = '';
  @State shotCount: number = 0;
  @State shotAppCount: number = 0;
  @State captureOn: number = 0;
  @State captureOff: number = 0;
  @State screenshotPulses: number = 0;
  @State recordingPulses: number = 0;
  @State verdict: string = 'idle';
  @State verdictDetail: string = 'waiting for a capture event';
  @State lastShotDelta: number = 0;
  @State hasShotDelta: boolean = false;
  @State captureActive: boolean = false;
  @State lastPulseMs: number = 0;
  @State lastPulseKind: string = '-';
  @State flashArmed: boolean = true;
  @State pollOn: boolean = false;
  @State shotAppOn: boolean = true;
  @State pageListenerOn: boolean = false;
  @State guideVisible: boolean = false;
  @State overlayVisible: boolean = false;
  @State overlayTitle: string = '';
  @State overlayTime: string = '';
  @State overlayCount: number = 0;
  @State eventCount: number = 0;

  private store: ProbeStore = ProbeStore.get();
  private scroller: Scroller = new Scroller();
  private pageWindow: window.Window | null = null;
  private clockTimer: number = -1;
  private hideOverlayTimer: number = -1;

  private onStoreChange: () => void = (): void => {
    this.syncFromStore();
  };

  aboutToAppear(): void {
    this.syncFromStore();
    this.store.subscribe(this.onStoreChange);
    this.store.onShot((event: ProbeEvent): void => {
      this.flashScreenshot(event);
    });
    this.nowText = formatClock(Date.now());
    this.clockTimer = setInterval((): void => {
      this.nowText = formatClock(Date.now());
      this.captured = readCaptured();
    }, 100);

    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      window.getLastWindow(context).then((win: window.Window): void => {
        this.pageWindow = win;
      }).catch((err: Error): void => {
        hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
      });
    }
  }

  aboutToDisappear(): void {
    this.store.unsubscribe(this.onStoreChange);
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    if (this.hideOverlayTimer >= 0) {
      clearTimeout(this.hideOverlayTimer);
      this.hideOverlayTimer = -1;
    }
  }

  private syncFromStore(): void {
    this.events = this.store.events.slice();
    this.eventCount = this.events.length;
    const stats = this.store.stats;
    this.shotCount = stats.shots;
    this.shotAppCount = stats.shotsApp;
    this.captureOn = stats.captureOn;
    this.captureOff = stats.captureOff;
    this.screenshotPulses = stats.screenshotPulses;
    this.recordingPulses = stats.recordingPulses;
    this.verdict = stats.lastVerdict;
    this.verdictDetail = stats.lastVerdictDetail;
    this.lastShotDelta = stats.lastShotToCapture;
    this.hasShotDelta = stats.hasShotDelta;
    this.captureActive = stats.captureActive;
    this.lastPulseMs = stats.lastPulseMs;
    this.lastPulseKind = stats.lastPulseKind;
    setTimeout((): void => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 30);
  }

  private flashScreenshot(event: ProbeEvent): void {
    if (!this.flashArmed) {
      return;
    }
    this.overlayCount = this.overlayCount + 1;
    this.overlayTitle = 'SCREENSHOT DETECTED  #' + this.overlayCount.toString();
    this.overlayTime = event.clock + '  (isCaptured=' + event.isCaptured + ')';
    this.overlayVisible = true;
    if (this.hideOverlayTimer >= 0) {
      clearTimeout(this.hideOverlayTimer);
    }
    this.hideOverlayTimer = setTimeout((): void => {
      this.overlayVisible = false;
      this.hideOverlayTimer = -1;
    }, 2000);
  }

  private verdictColor(): string {
    if (this.verdict === 'SCREENSHOT') {
      return '#0A59F7';
    }
    if (this.verdict === 'RECORDING / CAST') {
      return '#E84026';
    }
    return '#8C8C8C';
  }

  private kindColor(kind: EventKind): string {
    if (kind === EventKind.SHOT) {
      return '#0A59F7';
    }
    if (kind === EventKind.SHOT_APP) {
      return '#6E5EF6';
    }
    if (kind === EventKind.SAMPLE) {
      return '#9E9E9E';
    }
    if (kind === EventKind.INFO) {
      return '#8C8C8C';
    }
    return '#E84026';
  }

  private copyLog(): void {
    const text = this.store.toText();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      this.getUIContext().getPromptAction().showToast({
        message: '日志已复制（' + this.events.length.toString() + ' 条事件）',
        duration: 2000
      });
    }).catch((err: Error): void => {
      this.getUIContext().getPromptAction().showToast({
        message: '复制失败: ' + err.message,
        duration: 2500
      });
    });
  }

  @Builder
  Header() {
    Row() {
      Column() {
        Text('Capture Probe')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
        Text('screenshot vs screen recording')
          .fontSize(11)
          .fontColor('#8C8C8C')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Row() {
        Circle()
          .width(7)
          .height(7)
          .fill(this.captured ? '#E84026' : '#2BA471')
          .margin({ right: 5 })
        Text(this.captured ? 'BEING CAPTURED' : 'NOT CAPTURED')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.captured ? '#E84026' : '#2BA471')
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(10)
      .backgroundColor(this.captured ? '#FDECEA' : '#E8F7F0')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }

  @Builder
  StatusCard() {
    Column() {
      Row() {
        Text(this.nowText)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontColor('#1A1A1A')
        Blank()
        Column() {
          Text('isCaptured()')
            .fontSize(9)
            .fontColor('#8C8C8C')
          Text(readCaptured() ? 'true' : 'false')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(readCaptured() ? '#E84026' : '#2BA471')
            .fontFamily('monospace')
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Row() {
        Text('LAST VERDICT')
          .fontSize(9)
          .fontColor('#8C8C8C')
          .margin({ right: 8 })
        Text(this.verdict)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.verdictColor())
      }
      .width('100%')
      .margin({ top: 10 })

      Text(this.verdictDetail)
        .fontSize(11)
        .fontColor('#5C5C5C')
        .width('100%')
        .margin({ top: 2 })

      if (this.captureActive) {
        Text('持续捕获中：isCaptured=true，等待 capture=false 结束')
          .fontSize(10)
          .fontColor('#D9730D')
          .width('100%')
          .margin({ top: 3 })
      }

      Row() {
        Text('shot↔capture Δ: ' + (!this.hasShotDelta ? '—' :
          (this.lastShotDelta >= 0 ? '+' : '') + this.lastShotDelta.toString() + ' ms'))
          .fontSize(10)
          .fontColor('#5C5C5C')
        Blank()
        Text('last pulse: ' + (this.lastPulseMs === 0 ? '—' :
          this.lastPulseMs.toString() + ' ms / ' + this.lastPulseKind))
          .fontSize(10)
          .fontColor('#5C5C5C')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .padding(12)
    .margin({ left: 16, right: 16, top: 4 })
    .borderRadius(14)
    .backgroundColor(Color.White)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Counters() {
    Flex({ wrap: FlexWrap.Wrap }) {
      CounterChip({ label: 'window shot', value: this.shotCount, color: '#0A59F7' })
      CounterChip({ label: 'appEvent', value: this.shotAppCount, color: '#6E5EF6' })
      CounterChip({ label: 'capture true', value: this.captureOn, color: '#E84026' })
      CounterChip({ label: 'capture false', value: this.captureOff, color: '#2BA471' })
      CounterChip({ label: 'shot pulses', value: this.screenshotPulses, color: '#0A59F7' })
      CounterChip({ label: 'rec pulses', value: this.recordingPulses, color: '#E84026' })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  Controls() {
    Column() {
      Row() {
        SwitchRow({
          label: '截图闪屏',
          isOn: this.flashArmed,
          onChange: (value: boolean): void => {
            this.flashArmed = value;
          }
        })
        SwitchRow({
          label: 'isCaptured 轮询',
          isOn: this.pollOn,
          onChange: (value: boolean): void => {
            this.pollOn = value;
            CaptureMonitor.setPolling(value);
          }
        })
      }
      .width('100%')

      Row() {
        SwitchRow({
          label: 'appEvent 监听',
          isOn: this.shotAppOn,
          onChange: (value: boolean): void => {
            this.shotAppOn = value;
            CaptureMonitor.setShotAppListener(value);
          }
        })
        SwitchRow({
          label: '页面级 listener',
          isOn: this.pageListenerOn,
          onChange: (value: boolean): void => {
            this.pageListenerOn = value;
            CaptureMonitor.setPageListener(value, this.pageWindow);
          }
        })
      }
      .width('100%')

      Row() {
        Button('测试步骤')
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#EDEFF2')
          .fontColor('#1A1A1A')
          .onClick((): void => {
            this.guideVisible = !this.guideVisible;
          })
        Button('清空')
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .margin({ left: 8 })
          .backgroundColor('#EDEFF2')
          .fontColor('#1A1A1A')
          .onClick((): void => {
            this.overlayCount = 0;
            this.store.reset();
          })
        Button('复制日志')
          .fontSize(11)
          .height(30)
          .layoutWeight(1)
          .margin({ left: 8 })
          .backgroundColor('#0A59F7')
          .fontColor(Color.White)
          .onClick((): void => {
            this.copyLog();
          })
      }
      .width('100%')
      .margin({ top: 2 })

      Button('绑定系统录屏服务（诊断）')
        .fontSize(11)
        .height(30)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor('#FFF1E6')
        .fontColor('#D9730D')
        .onClick((): void => {
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          CaptureMonitor.toggleRecorderService(context);
        })

      Button('Web 屏幕共享（持续捕获诊断）')
        .fontSize(11)
        .height(30)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor('#EAF2FF')
        .fontColor('#0A59F7')
        .onClick((): void => {
          router.pushUrl({ url: 'pages/ShareProbe' }).catch((err: Error): void => {
            this.getUIContext().getPromptAction().showToast({ message: err.message, duration: 2500 });
          });
        })

      if (this.guideVisible) {
        Column() {
          Text('① 停留在本页，按 电源键+音量下 截屏')
            .fontSize(10)
            .fontColor('#5C5C5C')
          Text('② 从控制中心开始/停止屏幕录制')
            .fontSize(10)
            .fontColor('#5C5C5C')
          Text('③ 观察日志中 SHOT 与 CAPTURE true 的先后与 Δ')
            .fontSize(10)
            .fontColor('#5C5C5C')
          Text('④ 截屏后去相册看：画面里有没有红色闪屏')
            .fontSize(10)
            .fontColor('#5C5C5C')
          Text('⑤ 投屏/录屏时不会触发 window 截屏事件')
            .fontSize(10)
            .fontColor('#5C5C5C')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(10)
        .margin({ top: 8 })
        .borderRadius(10)
        .backgroundColor('#FFF8E5')
      }
    }
    .padding({ left: 16, right: 16, top: 10 })
  }

  @Builder
  EventRow(item: ProbeEvent) {
    Column() {
      Row() {
        Text(item.clock)
          .fontSize(10)
          .fontFamily('monospace')
          .fontColor('#8C8C8C')
          .width(78)
        Text(item.kind)
          .fontSize(9)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor(this.kindColor(item.kind))
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(4)
        Text(item.flag)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .margin({ left: 6 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('+' + item.delta.toString() + 'ms')
          .fontSize(9)
          .fontFamily('monospace')
          .fontColor('#B0B0B0')
      }
      .width('100%')

      Row() {
        Text(item.note)
          .fontSize(10)
          .fontColor('#5C5C5C')
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('isCaptured=' + item.isCaptured)
          .fontSize(9)
          .fontFamily('monospace')
          .fontColor('#B0B0B0')
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  LogPanel() {
    Column() {
      Row() {
        Text('EVENT TIMELINE')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor('#8C8C8C')
        Blank()
        Text(this.eventCount.toString() + ' events · 关联窗口 ' + CORRELATION_MS.toString() + 'ms')
          .fontSize(9)
          .fontColor('#B0B0B0')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })

      List({ scroller: this.scroller }) {
        ForEach(this.events, (item: ProbeEvent): void => {
          ListItem() {
            this.EventRow(item)
          }
        }, (item: ProbeEvent): string => item.id.toString())
      }
      .divider({ strokeWidth: 0.5, color: '#E8E8E8' })
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Color.White)
      .borderRadius({ topLeft: 14, topRight: 14 })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .layoutWeight(1)
    .margin({ top: 8 })
  }

  @Builder
  FlashOverlay() {
    Column() {
      Text('🔴')
        .fontSize(34)
      Text(this.overlayTitle)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
      Text(this.overlayTime)
        .fontSize(13)
        .fontColor('#FFE2DE')
        .fontFamily('monospace')
        .margin({ top: 6 })
      Text('hide sensitive content here')
        .fontSize(11)
        .fontColor('#FFC9C2')
        .margin({ top: 14 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#E81123')
    .opacity(0.94)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.Header()
        this.StatusCard()
        this.Counters()
        this.Controls()
        this.LogPanel()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F2F3F5')

      if (this.overlayVisible) {
        this.FlashOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
