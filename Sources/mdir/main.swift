import Darwin
import Foundation

// 목록 정렬 기준은 의도적으로 단순하게 유지한다.
// 인터랙티브 모드와 배치 모드가 동일한 정렬 규칙을 공유해야 하므로
// enum 하나로 정렬 상태와 표시 타이틀을 같이 관리한다.
enum SortMode: CaseIterable {
    case name
    case size
    case modified

    var title: String {
        switch self {
        case .name: return "NAME"
        case .size: return "SIZE"
        case .modified: return "TIME"
        }
    }
}

// 명령행에서 파싱된 시작 옵션 모음.
// 런타임 중 동적으로 바뀌는 상태와는 분리해서, "시작 시 기본값"만 담는다.
struct Options {
    var paths: [String] = []
    var showHidden = false
    var sortMode: SortMode = .name
    var showHelp = false
}

// 파일/디렉터리 한 건에 대한 화면 표시용 메타데이터.
// 화면 렌더링, 실행 가능 여부 판단, 권한 변경, 비교 등에서 반복 사용하므로
// 디렉터리 스캔 시 필요한 정보를 최대한 한 번에 계산해 둔다.
struct FileEntry {
    let name: String
    let path: String
    let isDirectory: Bool
    let isApplicationBundle: Bool
    let isParentItem: Bool
    let isHidden: Bool
    let size: UInt64
    let modifiedAt: Date
    let mode: mode_t
    let ownerID: uid_t
    let groupID: gid_t
    let owner: String
    let group: String
}

// 두 파일 비교 결과를 간단한 값 객체로 분리해
// 비교 로직과 화면 메시지 조합 로직을 분리한다.
struct FileCompareResult {
    let identical: Bool
    let offset: UInt64
    let leftSize: UInt64
    let rightSize: UInt64
}

// 좌/우 패널 각각의 독립 상태.
// 선택 위치, 스크롤 위치, 현재 경로를 패널 단위로 유지해야
// 양쪽 패널을 서로 간섭 없이 탐색할 수 있다.
struct PaneState {
    var currentPath: String
    var items: [FileEntry] = []
    var selectedIndex = 0
    var scrollOffset = 0
    var history: [String]
    var historyIndex: Int

    init(path: String) {
        self.currentPath = path
        self.history = [path]
        self.historyIndex = 0
    }
}

// 현재 터미널 크기.
// 매 렌더마다 컬럼/행 수를 확인해 동적으로 패널 폭을 계산한다.
struct TerminalSize {
    let rows: Int
    let cols: Int
}

// 날짜/숫자 포맷 유틸리티.
// DOS 느낌의 고정 폭 출력이 목적이므로 Locale 의존성을 최소화한다.
struct Formatter {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy-MM-dd HH:mm"
        return formatter
    }()

    func date(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    func size(_ value: UInt64) -> String {
        // 대형 라이브러리를 쓰지 않고 쉼표 구분 숫자를 직접 만든다.
        // 터미널 도구에서는 이 정도 단순 포맷이 가장 예측 가능하다.
        let raw = String(value)
        let reversed = String(raw.reversed())
        let grouped = stride(from: 0, to: reversed.count, by: 3).map { index -> String in
            let start = reversed.index(reversed.startIndex, offsetBy: index)
            let end = reversed.index(start, offsetBy: min(3, reversed.count - index))
            return String(reversed[start..<end])
        }
        return grouped.joined(separator: ",").reversed().map(String.init).joined()
    }
}

// 인터랙티브 터미널 세션 관리 객체.
// raw mode 전환, 대체 화면 버퍼 진입/복귀, 깜빡임 완화를 위한 렌더 캐시,
// 멀티바이트 키 입력 버퍼까지 한 곳에서 담당한다.
final class TerminalSession {
    private var original = termios()
    private var active = false
    private var lastBody = ""
    private var lastStatus = ""
    private var pendingBytes: [UInt8] = []

    func begin() throws {
        // interactive 모드는 실제 TTY에서만 동작 가능하다.
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw NSError(domain: "mdir", code: 1, userInfo: [NSLocalizedDescriptionKey: "interactive terminal is not available"])
        }

        var raw = original
        // canonical 모드/echo/signals 를 끄고 즉시 키 입력을 받는다.
        raw.c_iflag &= ~(UInt(BRKINT | ICRNL | INPCK | ISTRIP | IXON))
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_cflag |= UInt(CS8)
        raw.c_lflag &= ~(UInt(ECHO | ICANON | IEXTEN | ISIG))
        raw.c_cc.16 = 0
        raw.c_cc.17 = 1

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw NSError(domain: "mdir", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to switch terminal to raw mode"])
        }

        active = true
        // 외부 편집기나 실행 파일에서 복귀한 직후에도 반드시 전체 재렌더가 일어나도록
        // begin/end 진입 시 캐시를 비운다.
        lastBody = ""
        lastStatus = ""
        write("\u{001B}[?1049h\u{001B}[?25l\u{001B}[2J\u{001B}[H")
    }

    func end() {
        guard active else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        write("\u{001B}[?25h\u{001B}[?1049l")
        active = false
        lastBody = ""
        lastStatus = ""
    }

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func render(body: String, status: String, statusRow: Int) {
        // body 와 status 를 나눠 캐시하면
        // 하단 상태줄만 바뀌는 경우 전체 패널을 다시 그리지 않아 깜빡임이 줄어든다.
        if body != lastBody {
            lastBody = body
            write("\u{001B}[H")
            write(body)
        }

        if status != lastStatus {
            lastStatus = status
            write("\u{001B}[\(statusRow);1H")
            write(status)
            write("\u{001B}[J")
        }
    }

    func readKey() -> InputKey? {
        while true {
            if pendingBytes.isEmpty {
                // 여러 키가 한 번에 들어와도 버리지 않기 위해 내부 버퍼에 적재한다.
                var buffer = [UInt8](repeating: 0, count: 32)
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                guard count > 0 else { return nil }
                pendingBytes.append(contentsOf: buffer.prefix(count))
            }

            if pendingBytes.count >= 3 {
                // 화살표키는 ESC [ A/B/C/D 3바이트 시퀀스로 처리한다.
                let prefix = Array(pendingBytes.prefix(3))
                if prefix == [27, 91, 65] {
                    pendingBytes.removeFirst(3)
                    return .up
                }
                if prefix == [27, 91, 66] {
                    pendingBytes.removeFirst(3)
                    return .down
                }
                if prefix == [27, 91, 67] {
                    pendingBytes.removeFirst(3)
                    return .right
                }
                if prefix == [27, 91, 68] {
                    pendingBytes.removeFirst(3)
                    return .left
                }
            }

            guard let scalar = pendingBytes.first else { continue }
            pendingBytes.removeFirst()

            if scalar == 27 { return .escape }
            if scalar == 9 { return .tab }
            if scalar == 13 || scalar == 10 { return .enter }
            if scalar == 127 { return .backspace }
            if scalar >= 48 && scalar <= 57 {
                // chmod 입력 모드에서만 실제 의미가 있지만,
                // 키 판별은 여기서 공통 처리하는 편이 단순하다.
                return .digit(Character(UnicodeScalar(scalar)))
            }

            switch Character(UnicodeScalar(scalar)) {
            // 대소문자 차이를 신경 쓰지 않도록 필요한 키는 둘 다 허용한다.
            case "o", "O": return .openBundle
            case "e", "E": return .edit
            case "p": return .changePermissions
            case "q": return .quit
            case "h": return .toggleHidden
            case "s": return .cycleSort
            case "c": return .compare
            case "r": return .refresh
            case "j": return .down
            case "k": return .up
            default: return .other
            }
        }
    }

    func size() -> TerminalSize {
        var window = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 {
            return TerminalSize(rows: Int(window.ws_row), cols: Int(window.ws_col))
        }
        return TerminalSize(rows: 30, cols: 120)
    }
}

// readKey()의 결과를 앱 로직에서 해석하기 쉽게 추상화한 키 집합.
enum InputKey {
    case up
    case down
    case left
    case right
    case escape
    case tab
    case enter
    case backspace
    case digit(Character)
    case quit
    case openBundle
    case edit
    case changePermissions
    case toggleHidden
    case cycleSort
    case compare
    case refresh
    case other
}

struct MDirApp {
    private let fileManager = FileManager.default
    private let formatter = Formatter()
    private let currentUserID = getuid()
    // 실행 권한 판정 시 "현재 사용자가 속한 모든 그룹"을 빠르게 확인하기 위해
    // 시작 시 한 번만 계산해 Set 으로 들고 있는다.
    private let currentGroupIDs: Set<gid_t> = {
        let primary = getgid()
        let count = getgroups(0, nil)
        guard count > 0 else { return [primary] }
        let buffer = UnsafeMutablePointer<gid_t>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let filled = getgroups(count, buffer)
        guard filled >= 0 else { return [primary] }
        let groups = UnsafeBufferPointer(start: buffer, count: Int(filled))
        return Set(groups).union([primary])
    }()

    func run() throws {
        // 실행 진입점.
        // 1) 옵션 파싱
        // 2) 파일 비교 모드 여부 판정
        // 3) 인터랙티브/배치 모드 선택
        // 순서로 진행한다.
        let options = try parse(Array(CommandLine.arguments.dropFirst()))
        if isAppleTerminal() {
            print("mdir: Apple built-in terminals are not currently supported; they will be supported in the future.")
            return
        }
        if options.showHelp {
            printHelp()
            return
        }

        let resolvedPaths = options.paths.isEmpty ? [normalizePath(".")] : options.paths.map(normalizePath)
        if resolvedPaths.count == 2, areBothFiles(resolvedPaths) {
            try printCompare(left: resolvedPaths[0], right: resolvedPaths[1])
            return
        }

        let directories = try resolvedPaths.map(validateDirectory)
        if shouldRunInteractive() {
            try runInteractive(paths: directories, options: options)
        } else {
            try runBatch(paths: directories, options: options)
        }
    }

    private func shouldRunInteractive() -> Bool {
        // 강제 배치 모드 환경 변수와 실제 TTY 여부를 함께 본다.
        // 테스트/스크립트 환경에서는 interactive 로 진입하지 않게 하는 것이 중요하다.
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        return ProcessInfo.processInfo.environment["MDIR_FORCE_BATCH"] != "1"
    }

    func parse(_ arguments: [String]) throws -> Options {
        var options = Options()

        // 옵션과 경로를 한 번의 스캔으로 분리한다.
        // 현재 도구는 최대 2개 경로만 받도록 제한한다.
        for argument in arguments {
            if let option = parseOption(argument) {
                switch option {
                case .help:
                    options.showHelp = true
                case .showHidden:
                    options.showHidden = true
                case .sort(let mode):
                    options.sortMode = mode
                }
            } else {
                options.paths.append(argument)
            }
        }

        if options.paths.count > 2 {
            throw makeError("up to two paths are supported")
        }

        return options
    }

    private enum ParsedOption {
        case help
        case showHidden
        case sort(SortMode)
    }

    private func parseOption(_ argument: String) -> ParsedOption? {
        // DOS 스타일 스위치 문법을 단순 매핑한다.
        switch argument.lowercased() {
        case "/h", "/?":
            return .help
        case "/a:h":
            return .showHidden
        case "/o:n":
            return .sort(.name)
        case "/o:s":
            return .sort(.size)
        case "/o:d":
            return .sort(.modified)
        default:
            return nil
        }
    }

    private func normalizePath(_ path: String) -> String {
        // 상대 경로/~/절대 경로를 모두 절대 표준 경로로 정규화한다.
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardized.path
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(expanded).standardized.path
    }

    private func validateDirectory(_ path: String) throws -> String {
        // interactive/batch 패널 모드는 디렉터리만 시작점으로 받을 수 있다.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw makeError("path is not a directory: \(path)")
        }
        return path
    }

    private func areBothFiles(_ paths: [String]) -> Bool {
        // 두 인자가 모두 파일이면 패널 모드 대신 비교 모드로 진입한다.
        paths.count == 2 && paths.allSatisfy { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private func runBatch(paths: [String], options: Options) throws {
        // 배치 모드는 "읽기 쉬운 스냅샷"이 목표다.
        // 두 경로면 좌/우 비교 표, 한 경로면 단일 목록을 출력한다.
        if paths.count == 2 {
            let left = try loadDirectory(path: paths[0], options: options)
            let right = try loadDirectory(path: paths[1], options: options)
            print("MDIR 0.2 | Shell file manager")
            print("LEFT  \(paths[0])")
            print("RIGHT \(paths[1])")
            print("")
            print(batchRowHeader())
            let rows = max(left.count, right.count)
            for index in 0..<rows {
                let leftText = index < left.count ? batchPaneRow(left[index]) : String(repeating: " ", count: 58)
                let rightText = index < right.count ? batchPaneRow(right[index]) : String(repeating: " ", count: 58)
                print(leftText + " | " + rightText)
            }
            return
        }

        let entries = try loadDirectory(path: paths[0], options: options)
        print("MDIR 0.2 | Shell file manager")
        print("Directory of \(paths[0])")
        print("")
        for entry in entries {
            print(batchSingleRow(entry))
        }
    }

    private func runInteractive(paths: [String], options: Options) throws {
        // path 하나만 주면 좌우 패널을 같은 위치에서 시작한다.
        // path 둘이면 각각 좌/우 시작 경로로 사용한다.
        let leftPath = paths[0]
        let rightPath = paths.count == 2 ? paths[1] : paths[0]

        var state = InteractiveState(
            panes: [PaneState(path: leftPath), PaneState(path: rightPath)],
            activePane: 0,
            showHidden: options.showHidden,
            sortMode: options.sortMode,
            helpLine: "L/R Tab Enter O Bksp E P H/S/C/R/Q",
            infoLine: "",
            permissionInput: nil
        )

        try reloadPane(0, state: &state)
        try reloadPane(1, state: &state)
        updateInfoLineForActiveSelection(state: &state)

        let terminal = TerminalSession()
        try terminal.begin()
        defer { terminal.end() }

        while true {
            render(state: state, terminal: terminal)
            guard let key = terminal.readKey() else { continue }

            // chmod 입력 모드가 활성화된 동안에는 일반 키 처리보다 우선한다.
            if try handlePermissionInput(key: key, state: &state) {
                continue
            }

            switch key {
            case .quit:
                return
            case .tab:
                state.activePane = (state.activePane + 1) % 2
                updateInfoLineForActiveSelection(state: &state)
            case .left:
                state.activePane = 0
                updateInfoLineForActiveSelection(state: &state)
            case .right:
                state.activePane = 1
                updateInfoLineForActiveSelection(state: &state)
            case .up:
                moveSelection(delta: -1, paneIndex: state.activePane, state: &state)
            case .down:
                moveSelection(delta: 1, paneIndex: state.activePane, state: &state)
            case .enter:
                try openSelection(paneIndex: state.activePane, state: &state, terminal: terminal)
            case .backspace:
                try goParent(paneIndex: state.activePane, state: &state)
            case .openBundle:
                try openBundleContents(paneIndex: state.activePane, state: &state)
            case .edit:
                try editSelection(paneIndex: state.activePane, state: &state, terminal: terminal)
            case .changePermissions:
                try changePermissionsForSelection(paneIndex: state.activePane, state: &state)
            case .toggleHidden:
                state.showHidden.toggle()
                try reloadPane(0, state: &state)
                try reloadPane(1, state: &state)
                updateInfoLineForActiveSelection(state: &state, prefix: state.showHidden ? "Hidden files: ON  " : "Hidden files: OFF  ")
            case .cycleSort:
                state.sortMode = nextSortMode(after: state.sortMode)
                try reloadPane(0, state: &state)
                try reloadPane(1, state: &state)
                updateInfoLineForActiveSelection(state: &state, prefix: "Sort: \(state.sortMode.title)  ")
            case .compare:
                state.infoLine = compareSelectedFiles(state: state) ?? "Select a file in both panes to compare"
            case .refresh:
                try reloadPane(0, state: &state)
                try reloadPane(1, state: &state)
                updateInfoLineForActiveSelection(state: &state, prefix: "Refreshed  ")
            case .escape, .digit(_), .other:
                break
            }
        }
    }

    private struct InteractiveState {
        // UI 전체 상태.
        // 화면에 그려지는 대부분의 값은 이 구조체 하나에서 파생된다.
        var panes: [PaneState]
        var activePane: Int
        var showHidden: Bool
        var sortMode: SortMode
        var helpLine: String
        var infoLine: String
        var permissionInput: String?
    }

    private func reloadPane(_ index: Int, state: inout InteractiveState) throws {
        // 디렉터리를 다시 읽은 뒤 가능한 경우 기존 선택 파일명을 기준으로 선택을 복원한다.
        // 그래야 정렬 변경/숨김 토글/편집 복귀 뒤에도 사용자가 위치를 잃지 않는다.
        var pane = state.panes[index]
        let selectedName = pane.items.indices.contains(pane.selectedIndex) ? pane.items[pane.selectedIndex].name : nil
        let options = Options(paths: [], showHidden: state.showHidden, sortMode: state.sortMode, showHelp: false)
        pane.items = try loadDirectory(path: pane.currentPath, options: options)
        if let selectedName, let restored = pane.items.firstIndex(where: { $0.name == selectedName }) {
            pane.selectedIndex = restored
        } else {
            pane.selectedIndex = pane.items.isEmpty ? 0 : min(pane.selectedIndex, pane.items.count - 1)
        }
        pane.scrollOffset = min(pane.scrollOffset, max(0, pane.items.count - 1))
        state.panes[index] = pane
    }

    private func moveSelection(delta: Int, paneIndex: Int, state: inout InteractiveState) {
        // 범위를 벗어나지 않도록 clamp 한다.
        guard !state.panes[paneIndex].items.isEmpty else { return }
        var pane = state.panes[paneIndex]
        pane.selectedIndex = max(0, min(pane.items.count - 1, pane.selectedIndex + delta))
        state.panes[paneIndex] = pane
        updateInfoLineForActiveSelection(state: &state)
    }

    private func openSelection(paneIndex: Int, state: inout InteractiveState, terminal: TerminalSession) throws {
        // Enter 키의 실제 의미를 모두 여기서 분기한다.
        // 우선순위:
        // 1) .app 번들 실행
        // 2) 일반 디렉터리 진입
        // 3) 실행 권한이 있는 파일 실행
        // 4) 그 외는 정보만 유지
        var pane = state.panes[paneIndex]
        guard pane.items.indices.contains(pane.selectedIndex) else { return }
        let selected = pane.items[pane.selectedIndex]

        if selected.isApplicationBundle {
            // 앱 번들은 일반 폴더처럼 들어가지 않고 기본적으로 실행한다.
            // 내부를 보고 싶을 때는 별도 O 키를 사용한다.
            terminal.end()
            defer { try? terminal.begin() }
            let arguments = try promptExecutableArguments(for: selected.path)
            try launchApplicationBundle(at: selected.path, arguments: arguments)
            try reloadPane(paneIndex, state: &state)
            updateInfoLineForActiveSelection(state: &state, prefix: "Launched  ")
        } else if selected.isDirectory {
            // 일반 폴더는 패널 경로를 바꾸고 히스토리에도 반영한다.
            pane.currentPath = selected.path
            if pane.history.last != selected.path {
                pane.history.append(selected.path)
                pane.historyIndex = pane.history.count - 1
            }
            state.panes[paneIndex] = pane
            try reloadPane(paneIndex, state: &state)
            updateInfoLineForActiveSelection(state: &state)
        } else if canExecute(entry: selected) {
            // 실행 파일은 인자를 먼저 받은 뒤 child process 로 실행한다.
            terminal.end()
            defer { try? terminal.begin() }
            let arguments = try promptExecutableArguments(for: selected.path)
            try spawnExecutable(path: selected.path, arguments: arguments, waitForKeyPrompt: true)
            try reloadPane(paneIndex, state: &state)
            updateInfoLineForActiveSelection(state: &state, prefix: "Ran  ")
        } else {
            updateInfoLineForActiveSelection(state: &state)
        }
    }

    private func openBundleContents(paneIndex: Int, state: inout InteractiveState) throws {
        // .app 내부 구조 탐색은 Enter 와 별개로 분리한다.
        // 사용자가 번들의 Resources / MacOS / Info.plist 등을 점검할 수 있어야 하기 때문이다.
        var pane = state.panes[paneIndex]
        guard pane.items.indices.contains(pane.selectedIndex) else { return }
        let selected = pane.items[pane.selectedIndex]
        guard selected.isApplicationBundle else {
            state.infoLine = "Bundle browse: select a .app folder"
            return
        }

        pane.currentPath = selected.path
        if pane.history.last != selected.path {
            pane.history.append(selected.path)
            pane.historyIndex = pane.history.count - 1
        }
        state.panes[paneIndex] = pane
        try reloadPane(paneIndex, state: &state)
        updateInfoLineForActiveSelection(state: &state, prefix: "Bundle  ")
    }

    private func goParent(paneIndex: Int, state: inout InteractiveState) throws {
        // 현재 패널만 상위 디렉터리로 이동한다.
        var pane = state.panes[paneIndex]
        let current = pane.currentPath
        guard current != "/" else { return }
        let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
        pane.currentPath = parent.isEmpty ? "/" : parent
        if pane.history.last != pane.currentPath {
            pane.history.append(pane.currentPath)
            pane.historyIndex = pane.history.count - 1
        }
        state.panes[paneIndex] = pane
        try reloadPane(paneIndex, state: &state)
        updateInfoLineForActiveSelection(state: &state)
    }

    private func updateInfoLineForActiveSelection(state: inout InteractiveState, prefix: String = "") {
        // 하단 정보줄은 "현재 활성 패널의 현재 선택"을 기준으로 만든다.
        // 별도 상태 캐시를 두지 않고 매번 현재 선택에서 재생성하는 편이 일관성이 높다.
        let pane = state.panes[state.activePane]
        guard pane.items.indices.contains(pane.selectedIndex) else {
            let fallback = URL(fileURLWithPath: pane.currentPath).lastPathComponent
            state.infoLine = prefix.isEmpty ? fallback : prefix + fallback
            return
        }

        let selected = pane.items[pane.selectedIndex]
        if selected.isParentItem {
            state.infoLine = prefix + "[..]"
        } else if selected.isApplicationBundle {
            state.infoLine = prefix + "\(selected.name)  app bundle"
        } else if selected.isDirectory {
            state.infoLine = prefix + "\(selected.name)  directory"
        } else {
            let fileInfo = "\(selected.name)  owner:\(selected.owner) group:\(selected.group) perms:\(permissionString(selected.mode, directory: false))"
            state.infoLine = prefix + fileInfo
        }
    }

    private func handlePermissionInput(key: InputKey, state: inout InteractiveState) throws -> Bool {
        // permissionInput 이 nil 이 아니면 chmod 입력 모드로 간주한다.
        // 이 상태에서는 숫자/Enter/Esc/Backspace 만 의미 있고 나머지 키는 소비한다.
        guard let currentInput = state.permissionInput else { return false }

        switch key {
        case .digit(let digit):
            guard digit >= "0", digit <= "7" else {
                state.infoLine = permissionPromptLine(state: state, message: "Use octal digits 0-7")
                return true
            }
            if currentInput.count < 3 {
                state.permissionInput = currentInput + String(digit)
            }
            state.infoLine = permissionPromptLine(state: state)
            return true
        case .backspace:
            state.permissionInput = String(currentInput.dropLast())
            state.infoLine = permissionPromptLine(state: state)
            return true
        case .escape:
            state.permissionInput = nil
            updateInfoLineForActiveSelection(state: &state, prefix: "chmod cancelled  ")
            return true
        case .enter:
            guard let mode = modeFromOctalString(currentInput) else {
                state.infoLine = permissionPromptLine(state: state, message: "Enter exactly 3 octal digits")
                return true
            }
            try applyPermissionInput(mode: mode, state: &state)
            return true
        default:
            return true
        }
    }

    private func permissionPromptLine(state: InteractiveState, message: String? = nil) -> String {
        // chmod 입력 중 사용자에게 현재 권한, 입력 중 값, 적용 방법을 한 줄로 보여준다.
        let pane = state.panes[state.activePane]
        guard pane.items.indices.contains(pane.selectedIndex) else {
            return "chmod: no selection"
        }

        let selected = pane.items[pane.selectedIndex]
        guard !selected.isParentItem else {
            return "chmod: [..] cannot be modified"
        }

        let input = state.permissionInput ?? ""
        let current = String(format: "%03o", selected.mode & 0o777)
        let target = selected.name
        let base = "chmod \(current) -> [\(input)] target:\(target) Enter apply Esc cancel"
        if let message {
            return "\(base)  \(message)"
        }
        return base
    }

    private func applyPermissionInput(mode: mode_t, state: inout InteractiveState) throws {
        // chmod 성공 후에는 패널을 다시 읽어 실제 권한 문자열이 즉시 화면에 반영되게 한다.
        let paneIndex = state.activePane
        let pane = state.panes[paneIndex]
        guard pane.items.indices.contains(pane.selectedIndex) else { return }
        let selected = pane.items[pane.selectedIndex]
        guard !selected.isParentItem else { return }

        guard chmod(selected.path, mode) == 0 else {
            throw makeError("failed to change permissions: \(selected.path)")
        }

        state.permissionInput = nil
        try reloadPane(paneIndex, state: &state)
        updateInfoLineForActiveSelection(state: &state, prefix: "chmod \(String(format: "%03o", mode))  ")
    }

    private func changePermissionsForSelection(paneIndex: Int, state: inout InteractiveState) throws {
        // P 키는 즉시 chmod 하지 않고 입력 모드만 시작한다.
        let pane = state.panes[paneIndex]
        guard pane.items.indices.contains(pane.selectedIndex) else { return }
        let selected = pane.items[pane.selectedIndex]
        guard !selected.isParentItem else {
            state.infoLine = "chmod: [..] cannot be modified"
            return
        }

        state.permissionInput = ""
        state.infoLine = permissionPromptLine(state: state)
    }

    private func editSelection(paneIndex: Int, state: inout InteractiveState, terminal: TerminalSession) throws {
        // 편집은 오직 일반 파일만 허용한다.
        // 디렉터리/.app 은 편집 대상이 아니므로 바로 차단한다.
        let pane = state.panes[paneIndex]
        guard pane.items.indices.contains(pane.selectedIndex) else { return }
        let selected = pane.items[pane.selectedIndex]

        guard !selected.isParentItem else {
            state.infoLine = "Edit: [..] cannot be opened"
            return
        }

        guard !selected.isDirectory else {
            state.infoLine = "Edit: directories cannot be opened in vi"
            return
        }

        terminal.end()
        defer { try? terminal.begin() }
        try spawnExecutable(path: "/usr/bin/vi", arguments: [selected.path], waitForKeyPrompt: false)

        try reloadPane(paneIndex, state: &state)
        updateInfoLineForActiveSelection(state: &state, prefix: "Edited  ")
    }

    private func canExecute(entry: FileEntry) -> Bool {
        // 요청사항대로 owner/group/other 실행 비트를 순서대로 판정한다.
        // access(2) 대신 현재 캐시된 uid/gid/mode 로 직접 계산하는 방식이다.
        guard !entry.isDirectory, !entry.isParentItem else { return false }
        if entry.ownerID == currentUserID {
            return (entry.mode & S_IXUSR) != 0
        }
        if currentGroupIDs.contains(entry.groupID) {
            return (entry.mode & S_IXGRP) != 0
        }
        return (entry.mode & S_IXOTH) != 0
    }

    private func promptExecutableArguments(for path: String) throws -> [String] {
        // raw mode 를 내린 뒤 일반 입력 한 줄을 받아 인자 배열로 파싱한다.
        // 사용자가 그냥 Enter 를 치면 빈 배열이 반환된다.
        let name = URL(fileURLWithPath: path).lastPathComponent
        FileHandle.standardOutput.write(Data("\nArguments for \(name): ".utf8))
        guard let line = readLine(strippingNewline: true) else {
            FileHandle.standardOutput.write(Data("\n".utf8))
            return []
        }
        return try parseCommandLineArguments(line)
    }

    private func launchApplicationBundle(at path: String, arguments: [String]) throws {
        // macOS 앱 번들은 실행 파일을 직접 찾지 않고 open -args 경로를 사용한다.
        // 그래야 Finder/AppKit 쪽 번들 실행 규칙을 그대로 따른다.
        var openArguments = [path]
        if !arguments.isEmpty {
            openArguments.append("--args")
            openArguments.append(contentsOf: arguments)
        }
        try spawnExecutable(path: "/usr/bin/open", arguments: openArguments, waitForKeyPrompt: true)
    }

    private func spawnExecutable(path: String, arguments: [String] = [], waitForKeyPrompt: Bool) throws {
        // 외부 프로그램 실행 공통 루틴.
        // vi, 일반 실행 파일, open(.app) 모두 여기를 통해 나간다.
        // Swift Process 대신 posix_spawn 을 사용한 이유는
        // 현재 터미널 세션에서 더 예측 가능하게 붙기 때문이다.
        var pid = pid_t()
        let command = strdup(path)
        let rawArguments = arguments.map { strdup($0) }
        defer {
            free(command)
            for item in rawArguments {
                free(item)
            }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [command]
        argv.append(contentsOf: rawArguments)
        argv.append(nil)

        let spawnResult = posix_spawn(&pid, command, nil, nil, &argv, environ)
        guard spawnResult == 0 else {
            throw makeError("failed to launch: \(path)")
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR {
                throw makeError("failed to wait for: \(path)")
            }
        }

        if waitForKeyPrompt {
            // 실행 결과를 사용자가 확인할 수 있도록 아무 키 대기 지점을 둔다.
            FileHandle.standardOutput.write(Data("\n[Press Anykey]".utf8))
            var byte: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &byte, 1)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private func parseCommandLineArguments(_ line: String) throws -> [String] {
        // 아주 작은 shell 스타일 파서.
        // 공백 분리, 작은/큰따옴표, 백슬래시 이스케이프만 지원한다.
        // 복잡한 shell expansion 은 의도적으로 지원하지 않는다.
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escape = false

        for character in line {
            if escape {
                current.append(character)
                escape = false
                continue
            }

            if character == "\\" {
                escape = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if escape || quote != nil {
            throw makeError("invalid arguments: unmatched quote or escape")
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private func modeFromOctalString(_ value: String) -> mode_t? {
        // "755" 같은 3자리 octal 문자열만 허용한다.
        guard value.count == 3 else { return nil }
        var result: mode_t = 0
        for character in value {
            guard let digit = character.wholeNumberValue, digit >= 0, digit <= 7 else {
                return nil
            }
            result = (result << 3) | mode_t(digit)
        }
        return result
    }

    private func compareSelectedFiles(state: InteractiveState) -> String? {
        // 좌/우 패널에서 각각 현재 선택한 파일을 비교한다.
        // 디렉터리는 비교 대상에서 제외한다.
        let leftPane = state.panes[0]
        let rightPane = state.panes[1]
        guard
            leftPane.items.indices.contains(leftPane.selectedIndex),
            rightPane.items.indices.contains(rightPane.selectedIndex)
        else {
            return nil
        }

        let left = leftPane.items[leftPane.selectedIndex]
        let right = rightPane.items[rightPane.selectedIndex]
        guard !left.isDirectory, !right.isDirectory else {
            return nil
        }

        do {
            let result = try compareFiles(left: left.path, right: right.path)
            if result.identical {
                return "Compare: identical (\(formatter.size(result.leftSize)) bytes)"
            }
            return "Compare: different at offset \(formatter.size(result.offset))"
        } catch {
            return "Compare failed: \(error.localizedDescription)"
        }
    }

    private func nextSortMode(after mode: SortMode) -> SortMode {
        // 단순 순환 방식: NAME -> SIZE -> TIME -> NAME ...
        let all = SortMode.allCases
        guard let index = all.firstIndex(of: mode) else { return .name }
        return all[(index + 1) % all.count]
    }

    private func render(state: InteractiveState, terminal: TerminalSession) {
        // 전체 화면은 상단 헤더 + 좌우 본문 + 하단 상태 3줄 구조다.
        // body/status 를 분리해 TerminalSession 쪽에서 부분 갱신할 수 있게 한다.
        let size = terminal.size()
        let compatMode = isAppleTerminal()
        let paneHeight = max(8, size.rows - 6)
        let useDualPane = size.cols >= 80 && !compatMode
        let safeWidth = max(20, size.cols - 2)
        let paneWidth = useDualPane ? max(20, (safeWidth - 1) / 2) : safeWidth
        var body = ""
        let headerText = " Shell File Manager  Copyright : jayusop(jayusop@sk.com)  Sort:\(state.sortMode.title)  Hidden:\(state.showHidden ? "ON" : "OFF")"
        if compatMode {
            body += truncateVisible("MDIR 0.2 | Shell File Manager | Copyright : jayusop(jayusop@sk.com) | Sort:\(state.sortMode.title) | Hidden:\(state.showHidden ? "ON" : "OFF")", to: safeWidth) + "\u{001B}[K\n"
        } else {
            body += color(" MDIR 0.2 ", code: "46;30") + truncateVisible(headerText, to: max(0, safeWidth - 10)) + "\u{001B}[K\n"
        }

        if useDualPane && !compatMode {
            let leftLines = paneLines(for: state.panes[0], isActive: state.activePane == 0, height: paneHeight, width: paneWidth, useColor: true)
            let rightLines = paneLines(for: state.panes[1], isActive: state.activePane == 1, height: paneHeight, width: paneWidth, useColor: true)

            for row in 0..<max(leftLines.count, rightLines.count) {
                let left = row < leftLines.count ? leftLines[row] : String(repeating: " ", count: paneWidth)
                let right = row < rightLines.count ? rightLines[row] : String(repeating: " ", count: paneWidth)
                body += left + " " + right + "\u{001B}[K\n"
            }
        } else {
            let activePane = state.panes[state.activePane]
            let lines = paneLines(for: activePane, isActive: true, height: paneHeight, width: paneWidth, useColor: !compatMode)
            for line in lines {
                body += line + "\u{001B}[K\n"
            }
        }

        let status: String
        if compatMode {
            let footer = truncateVisible("\(state.helpLine) \(state.infoLine)", to: safeWidth)
            status = safePlainLine(footer, width: safeWidth) + "\n"
        } else {
            status =
                safePlainLine(String(repeating: "-", count: safeWidth), width: safeWidth) + "\n" +
                safePlainLine(state.helpLine, width: safeWidth) + "\n" +
                safePlainLine(state.infoLine, width: safeWidth) + "\n"
        }

        terminal.render(body: body, status: status, statusRow: max(1, paneHeight + 2))
    }

    private func paneLines(for pane: PaneState, isActive: Bool, height: Int, width: Int, useColor: Bool) -> [String] {
        // 패널 단위 렌더링.
        // 스크롤 범위를 계산한 뒤, 현재 보이는 행만 문자열 배열로 만든다.
        var lines: [String] = []
        let title = truncateVisible(pane.currentPath, to: width - 4)
        let titleLine = " " + padVisible(title, to: width - 2) + " "
        lines.append(useColor ? color(titleLine, code: isActive ? "44;97" : "100;97") : titleLine)
        // 폭 계산은 실제 표시 폭 기준으로 맞춘다.
        // width > 26 인 경우에도 "name + size + modified"가 한 줄을 넘지 않도록
        // 이름 칼럼에 충분한 여백을 남긴다.
        let nameWidth = max(8, width > 26 ? width - 26 : width - 7)
        let headerLine: String
        if width > 26 {
            headerLine = padVisible("Name", to: nameWidth) + " " + padVisible("Size", to: 9, alignRight: true) + " Modified"
        } else {
            headerLine = padVisible("Name", to: max(4, width - 6)) + " Size"
        }
        lines.append(useColor ? color(padVisible(headerLine, to: width), code: "47;30") : padVisible(headerLine, to: width))

        var pane = pane
        let visibleRows = max(1, height - 2)
        // 선택 위치가 화면 밖으로 나가지 않도록 scrollOffset 을 조정한다.
        if pane.selectedIndex < pane.scrollOffset {
            pane.scrollOffset = pane.selectedIndex
        } else if pane.selectedIndex >= pane.scrollOffset + visibleRows {
            pane.scrollOffset = pane.selectedIndex - visibleRows + 1
        }

        let rangeEnd = min(pane.items.count, pane.scrollOffset + visibleRows)
        for row in pane.scrollOffset..<rangeEnd {
            let entry = pane.items[row]
            let prefix = displayName(for: entry)
            let name = truncateVisible(prefix, to: nameWidth)
            let size = entry.isParentItem ? "<UP>" : (entry.isDirectory ? (entry.isApplicationBundle ? "<APP>" : "<DIR>") : formatter.size(entry.size))
            let line: String
            if width > 26 {
                let date = entry.isParentItem ? String(repeating: " ", count: 14) : formatter.date(entry.modifiedAt)
                line = padVisible(name, to: nameWidth) + " " + padVisible(size, to: 9, alignRight: true) + " " + date
            } else {
                line = padVisible(name, to: max(4, width - 6)) + " " + truncateVisible(size, to: 5)
            }
            let paddedLine = padVisible(line, to: width)

            // 선택 강조, .app, 일반 폴더 색을 분리한다.
            if useColor {
                if row == pane.selectedIndex {
                    lines.append(color(paddedLine, code: isActive ? "7" : "100;97"))
                } else if entry.isApplicationBundle {
                    lines.append(color(paddedLine, code: "35"))
                } else if entry.isDirectory {
                    lines.append(color(paddedLine, code: "32"))
                } else {
                    lines.append(paddedLine)
                }
            } else {
                lines.append(paddedLine)
            }
        }

        while lines.count < height {
            lines.append(String(repeating: " ", count: width))
        }
        return lines
    }

    private func loadDirectory(path: String, options: Options) throws -> [FileEntry] {
        // 디렉터리 스캔 시 stat 기반 메타데이터를 즉시 수집한다.
        // 이후 렌더/실행/권한 판정에서 다시 파일 시스템을 읽는 횟수를 줄이는 목적이다.
        let urls = try fileManager.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
        var entries: [FileEntry] = []

        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }

            let name = url.lastPathComponent
            let isHidden = name.hasPrefix(".")
            if !options.showHidden && isHidden {
                continue
            }

            let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            // .app 디렉터리는 일반 폴더와 구분해 앱 번들로 취급한다.
            let isApplicationBundle = isDirectory && name.lowercased().hasSuffix(".app")
            let owner = ownerName(st.st_uid)
            let group = groupName(st.st_gid)

            entries.append(
                FileEntry(
                    name: name,
                    path: url.path,
                    isDirectory: isDirectory,
                    isApplicationBundle: isApplicationBundle,
                    isParentItem: false,
                    isHidden: isHidden,
                    size: UInt64(st.st_size),
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                    mode: st.st_mode,
                    ownerID: st.st_uid,
                    groupID: st.st_gid,
                    owner: owner,
                    group: group
                )
            )
        }

        if path != "/" {
            // 상위 디렉터리 엔트리는 실제 파일 시스템 항목이 아니므로 가상 엔트리로 추가한다.
            let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
            entries.append(
                FileEntry(
                    name: "..",
                    path: parentPath.isEmpty ? "/" : parentPath,
                    isDirectory: true,
                    isApplicationBundle: false,
                    isParentItem: true,
                    isHidden: false,
                    size: 0,
                    modifiedAt: Date.distantPast,
                    mode: 0,
                    ownerID: 0,
                    groupID: 0,
                    owner: "",
                    group: ""
                )
            )
        }

        return entries.sorted { left, right in
            // 정렬 우선순위:
            // 1) [..]
            // 2) 디렉터리
            // 3) .app 번들
            // 4) 선택된 정렬 기준
            if left.isParentItem != right.isParentItem {
                return left.isParentItem && !right.isParentItem
            }

            if left.isDirectory != right.isDirectory {
                return left.isDirectory && !right.isDirectory
            }

            if left.isApplicationBundle != right.isApplicationBundle {
                return left.isApplicationBundle && !right.isApplicationBundle
            }

            switch options.sortMode {
            case .name:
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            case .size:
                if left.size != right.size { return left.size > right.size }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            case .modified:
                if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        }
    }

    private func ownerName(_ uid: uid_t) -> String {
        // 사용자명이 없으면 숫자 uid 를 그대로 보여준다.
        guard let pwd = getpwuid(uid) else { return String(uid) }
        return String(cString: pwd.pointee.pw_name)
    }

    private func groupName(_ gid: gid_t) -> String {
        // 그룹명도 동일한 방식으로 처리한다.
        guard let grp = getgrgid(gid) else { return String(gid) }
        return String(cString: grp.pointee.gr_name)
    }

    private func compareFiles(left: String, right: String) throws -> FileCompareResult {
        // 파일 크기가 다르면 가장 짧은 길이 지점에서 차이가 난 것으로 간주한다.
        // 크기가 같을 때만 실제 바이트 단위 비교를 진행한다.
        var leftStat = stat()
        var rightStat = stat()
        guard lstat(left, &leftStat) == 0, lstat(right, &rightStat) == 0 else {
            throw makeError("failed to stat files")
        }

        let leftSize = UInt64(leftStat.st_size)
        let rightSize = UInt64(rightStat.st_size)
        if leftSize != rightSize {
            return FileCompareResult(identical: false, offset: min(leftSize, rightSize), leftSize: leftSize, rightSize: rightSize)
        }

        guard let leftHandle = FileHandle(forReadingAtPath: left), let rightHandle = FileHandle(forReadingAtPath: right) else {
            throw makeError("failed to open files")
        }
        defer {
            try? leftHandle.close()
            try? rightHandle.close()
        }

        let chunk = 65536
        var offset: UInt64 = 0
        while true {
            // 대형 파일도 처리할 수 있도록 청크 단위로 읽는다.
            let leftData = leftHandle.readData(ofLength: chunk)
            let rightData = rightHandle.readData(ofLength: chunk)
            if leftData != rightData {
                let leftBytes = [UInt8](leftData)
                let rightBytes = [UInt8](rightData)
                let length = min(leftBytes.count, rightBytes.count)
                for index in 0..<length where leftBytes[index] != rightBytes[index] {
                    return FileCompareResult(identical: false, offset: offset + UInt64(index), leftSize: leftSize, rightSize: rightSize)
                }
                return FileCompareResult(identical: false, offset: offset + UInt64(length), leftSize: leftSize, rightSize: rightSize)
            }
            if leftData.isEmpty { break }
            offset += UInt64(leftData.count)
        }

        return FileCompareResult(identical: true, offset: 0, leftSize: leftSize, rightSize: rightSize)
    }

    private func printCompare(left: String, right: String) throws {
        let result = try compareFiles(left: left, right: right)
        print("MDIR 0.2 | Shell file manager")
        print("Compare files")
        print("left : \(left)")
        print("right: \(right)")
        print("")
        print("left size : \(formatter.size(result.leftSize)) bytes")
        print("right size: \(formatter.size(result.rightSize)) bytes")
        if result.identical {
            print("result    : identical")
        } else {
            print("result    : different")
            print("first diff: offset \(formatter.size(result.offset))")
        }
    }

    private func batchRowHeader() -> String {
        let header = "Mode Owner     Group        Size Modified         Name"
        return padVisible(header, to: 58) + " | " + padVisible(header, to: 58)
    }

    private func batchPaneRow(_ entry: FileEntry) -> String {
        let mode = permissionString(entry.mode, directory: entry.isDirectory)
        let owner = padVisible(entry.owner, to: 8)
        let group = padVisible(entry.group, to: 8)
        let size = padVisible(entry.isParentItem ? "<UP>" : (entry.isDirectory ? (entry.isApplicationBundle ? "<APP>" : "<DIR>") : formatter.size(entry.size)), to: 10, alignRight: true)
        let date = entry.isParentItem ? String(repeating: " ", count: 14) : formatter.date(entry.modifiedAt)
        let name = truncateVisible(displayName(for: entry), to: 16)
        return padVisible("\(mode) \(owner) \(group) \(size) \(date) \(name)", to: 58)
    }

    private func batchSingleRow(_ entry: FileEntry) -> String {
        let mode = permissionString(entry.mode, directory: entry.isDirectory)
        let owner = padVisible(entry.owner, to: 8)
        let group = padVisible(entry.group, to: 8)
        let size = padVisible(entry.isParentItem ? "<UP>" : (entry.isDirectory ? (entry.isApplicationBundle ? "<APP>" : "<DIR>") : formatter.size(entry.size)), to: 10, alignRight: true)
        let date = entry.isParentItem ? String(repeating: " ", count: 14) : formatter.date(entry.modifiedAt)
        let name = displayName(for: entry)
        return "\(mode) \(owner) \(group) \(size) \(date) \(name)"
    }

    private func permissionString(_ mode: mode_t, directory: Bool) -> String {
        var chars = Array(repeating: Character("-"), count: 10)
        chars[0] = directory ? "d" : "-"
        chars[1] = (mode & S_IRUSR) != 0 ? "r" : "-"
        chars[2] = (mode & S_IWUSR) != 0 ? "w" : "-"
        chars[3] = (mode & S_IXUSR) != 0 ? "x" : "-"
        chars[4] = (mode & S_IRGRP) != 0 ? "r" : "-"
        chars[5] = (mode & S_IWGRP) != 0 ? "w" : "-"
        chars[6] = (mode & S_IXGRP) != 0 ? "x" : "-"
        chars[7] = (mode & S_IROTH) != 0 ? "r" : "-"
        chars[8] = (mode & S_IWOTH) != 0 ? "w" : "-"
        chars[9] = (mode & S_IXOTH) != 0 ? "x" : "-"
        return String(chars)
    }

    private func color(_ text: String, code: String) -> String {
        "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func displayName(for entry: FileEntry) -> String {
        if entry.isParentItem {
            return "[..]"
        }
        if entry.isApplicationBundle {
            return "{\(entry.name)}"
        }
        if entry.isDirectory {
            return "[\(entry.name)]"
        }
        return entry.name
    }

    private func padVisible(_ text: String, to width: Int, alignRight: Bool = false) -> String {
        let truncated = truncateVisible(text, to: width)
        let padding = String(repeating: " ", count: max(0, width - truncated.count))
        return alignRight ? padding + truncated : truncated + padding
    }

    private func safePlainLine(_ text: String, width: Int) -> String {
        // macOS 기본 Terminal 에서는 마지막 컬럼까지 정확히 채우면
        // 자동 줄바꿈 pending 상태가 남아 다음 줄 렌더링이 어긋날 수 있다.
        // 마지막 1컬럼은 비워 두고 EL(K)로 나머지를 지우는 방식이 더 안전하다.
        let visibleWidth = max(1, width - 1)
        return truncateVisible(text, to: visibleWidth) + "\u{001B}[K"
    }

    private func isAppleTerminal() -> Bool {
        ProcessInfo.processInfo.environment["TERM_PROGRAM"] == "Apple_Terminal"
    }

    private func truncateVisible(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 3 else { return String(text.prefix(width)) }
        return String(text.prefix(width - 3)) + "..."
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "mdir", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func printHelp() {
        Swift.print(
            """
            MDIR 0.2 - Shell file manager

            Usage:
              mdir
              mdir <path>
              mdir <left-path> <right-path>
              mdir <left-file> <right-file>
              mdir /a:h
              mdir /o:n | /o:s | /o:d

            Interactive Keys:
              Left       activate left pane
              Right      activate right pane
              TAB        switch active pane
              Up/Down    move selection
              Enter      open directory, launch .app, or run executable file with arguments
              O          open selected .app bundle contents
              Backspace  go to parent directory
              E          edit selected file in vi
              P          enter chmod input mode (example: 644, 755)
              H          toggle hidden files
              S          cycle sort mode
              C          compare selected files from both panes
              R          refresh
              Q          quit

            Batch Mode:
              Set MDIR_FORCE_BATCH=1 to print a non-interactive snapshot.
            """
        )
    }
}

do {
    try MDirApp().run()
} catch {
    FileHandle.standardError.write(Data("mdir: \(error.localizedDescription)\n".utf8))
    Darwin.exit(1)
}
