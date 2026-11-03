import gene/c_sdk
import std/unittest

suite "native macOS SDK selection":
  test "respects an explicitly configured SDK without probing":
    var calls = 0
    let probe: SdkLinkProbe = proc(sdk: string): bool =
      inc calls
      false
    check compatibleMacSdk("/custom/sdk", "/sdks/MacOSX27.0.sdk",
      ["/sdks/MacOSX26.5.sdk"], probe) == "/custom/sdk"
    check calls == 0

  test "leaves a working default unchanged":
    var calls: seq[string]
    let probe: SdkLinkProbe = proc(sdk: string): bool =
      calls.add sdk
      true
    check compatibleMacSdk("", "/sdks/MacOSX27.0.sdk",
      ["/sdks/MacOSX26.5.sdk"], probe) == ""
    check calls == @["/sdks/MacOSX27.0.sdk"]

  test "chooses the newest SDK that actually links, using numeric versions":
    var calls: seq[string]
    let probe: SdkLinkProbe = proc(sdk: string): bool =
      calls.add sdk
      sdk in ["/sdks/MacOSX26.5.sdk", "/sdks/MacOSX26.10.sdk"]
    check compatibleMacSdk("", "/sdks/MacOSX.sdk",
      ["/sdks/MacOSX26.5.sdk", "/sdks/MacOSX26.4.sdk",
       "/sdks/MacOSX27.0.sdk", "/sdks/MacOSX26.10.sdk",
       "/sdks/MacOSXinvalid.sdk"], probe) == "/sdks/MacOSX26.10.sdk"
    check calls == @["/sdks/MacOSX.sdk", "/sdks/MacOSX27.0.sdk",
                     "/sdks/MacOSX26.10.sdk"]

  test "keeps ordinary build failure when no installed SDK works":
    let probe: SdkLinkProbe = proc(sdk: string): bool = false
    check compatibleMacSdk("", "/sdks/MacOSX27.0.sdk",
      ["/sdks/MacOSX26.5.sdk"], probe) == ""

  test "does not probe when discovery did not find a default":
    var calls = 0
    let probe: SdkLinkProbe = proc(sdk: string): bool =
      inc calls
      true
    check compatibleMacSdk("", "", ["/sdks/MacOSX26.5.sdk"], probe) == ""
    check calls == 0
