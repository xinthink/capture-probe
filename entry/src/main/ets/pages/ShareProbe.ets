/*
 * Diagnostic page: ask a local H5 page for getDisplayMedia() and grant it.
 *
 * This starts a *sustained* screen capture session owned by the Web engine, which
 * goes through the same display capture service that screen recording uses. It is
 * the closest thing to "recording" that a debug app can trigger on an emulator
 * without the system screen recorder. Watch the CaptureProbe timeline for
 * captureStatusChange(true) / (false) while starting and stopping the share.
 */

import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct ShareProbe {
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(12)
          .height(30)
          .backgroundColor('#EDEFF2')
          .fontColor('#1A1A1A')
          .onClick((): void => {
            router.back();
          })
        Blank()
        Text('WebRTC 屏幕共享（持续捕获诊断）')
          .fontSize(12)
          .fontColor('#1A1A1A')
      }
      .width('100%')
      .padding(12)

      Web({ src: $rawfile('share.html'), controller: this.controller })
        .onScreenCaptureRequest((event: OnScreenCaptureRequestEvent): void => {
          event.handler.grant({ captureMode: WebCaptureMode.HOME_SCREEN });
        })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#111111')
    }
    .width('100%')
    .height('100%')
  }
}
