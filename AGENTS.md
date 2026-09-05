# DSHShell maintenance notes

- This project is a native AppKit/WKWebView shell. Do not modify or vendor the DSH source; its managed checkout lives under Application Support at runtime.
- Keep injected web CSS centralized in `DSHShell/DSHShellApp.swift` and prefer stable semantic roles or `data-*` attributes over generated class names.
- Page chrome is non-selectable by default. Text selection is an explicit whitelist: form controls, editable composer content, chat content, standard alerts/status, and paragraphs inside dialogs. Preserve and extend this whitelist when new selectable content is found.
- The native New Conversation command is a fail-closed compatibility bridge to DSH's accessible New Session button. Keep its localized `aria-label` values centralized; never replace them with generated classes or positional selectors.
- `titlebarSafeAreaHeight` controls both the injected top offset and native drag strip height; keep those two behaviors aligned.
- Port 3080 cleanup may stop only a verified DSH process whose working directory is the managed checkout. Never terminate an unrelated listener.
- Keep user-facing error dialogs brief. Send full runtime output to the DSH Console and redact URL authentication tokens there.
- The Xcode target and scheme remain `DSHShell`; the distributed product name is `DeepSeek Harness`. Release artifacts are Universal, ad-hoc signed, explicitly unnotarized ZIPs.
- After changes, build the `DSHShell` scheme for macOS. Exercise launch/restart/quit behavior when touching runtime lifecycle code.
