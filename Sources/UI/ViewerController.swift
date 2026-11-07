import AppKit

/// Connects the session, the pipeline and the view. Navigation here does a cache lookup and
/// a layer commit, nothing else: all waiting happens in the pipeline.
@MainActor
final class ViewerController: NSObject, NSWindowDelegate {
    let session: LibrarySession
    let pipeline: Pipeline
    let view = ViewerView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
    let window: NSWindow

    private(set) var direction = 1
    private var repeating = false
    private var settled = true
    private var focused = false
    private var idle = false
    private var navigationToken = 0
    /// The file name the view is really showing, whose deletion is therefore legitimate.
    private(set) var visiblePhoto: PhotoKey?
    private(set) var shownTier: Tier?
    private var infoVisible = Preferences.infoVisible
    private var titlePending = false
    private let metadata = MetadataStore()

    /// The shape the window currently has, and the size it keeps across shapes.
    private var shapedAspect: CGFloat?
    private var chosenHeight: CGFloat = 750
    private var applyingShape = false

    /// Benchmark hooks.
    var onDisplayed: ((PhotoKey, Tier?) -> Void)?

    init(session: LibrarySession = LibrarySession(), diskDirectory: URL = DiskCache.defaultDirectory) {
        self.session = session
        let budget = Preferences.diskCacheBytes
        pipeline = Pipeline(
            budgets: .scaled(physicalMemory: ProcessInfo.processInfo.physicalMemory),
            disk: DiskCache(directory: diskDirectory, budget: budget)
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        setWindowButtonsVisible(false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        window.title = "BetterView"
        window.setFrameAutosaveName("Viewer")
        // Only the window with the photo's shape exists: no full-screen mode.
        window.collectionBehavior = .fullScreenNone
        window.minSize = NSSize(width: 200, height: 200)
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = view
        if !window.setFrameUsingName("Viewer") { window.center() }
        chosenHeight = window.frame.height

        view.onCommand = { [weak self] in self?.handle($0) }
        session.onEvent = { [weak self] in self?.handle($0) }
        pipeline.onFrame = { [weak self] in self?.frameArrived($0) }
        pipeline.onFailed = { [weak self] in self?.frameFailed($0) }
        pipeline.onStale = { [weak self] _ in self?.session.requestScan() }
        pipeline.onNeedsReplan = { [weak self] in self?.replan() }
        metadata.onLoaded = { [weak self] photo in
            guard let self, photo == self.session.list.current else { return }
            self.updateInfo()
        }

        updateTarget()
        pipeline.disk.load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        view.showMessage("⌘O pour ouvrir un dossier ou une photo")
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func open(_ urls: [URL]) {
        showWindow()
        visiblePhoto = nil
        for url in urls {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        session.open(urls)
    }

    // MARK: Target size

    private func updateTarget() {
        var size = CGSize.zero
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            size.width = max(size.width, screen.frame.width * scale)
            size.height = max(size.height, screen.frame.height * scale)
        }
        if size == .zero { size = CGSize(width: 3024, height: 1964) }
        pipeline.setTarget(size)
    }

    private func screensChanged() {
        updateTarget()
        shapedAspect = nil
        display()
        replan()
    }

    // MARK: Commands

    private func handle(_ command: ViewerCommand) {
        switch command {
        case .perform(let action, let isRepeat): perform(action, repeating: isRepeat)
        case .keyReleased:
            guard repeating else { return }
            repeating = false
            replan()
        case .hoverChanged(let inside): setWindowButtonsVisible(inside)
        case .openDropped(let urls): open(urls)
        case .zoomChanged:
            display()
            replan()
        }
    }

    func perform(_ action: ShortcutAction, repeating isRepeat: Bool = false) {
        switch action {
        case .next: step(1, repeating: isRepeat)
        case .previous: step(-1, repeating: isRepeat)
        case .jumpForward: step(10, repeating: isRepeat)
        case .jumpBackward: step(-10, repeating: isRepeat)
        case .first: jump(to: 0, direction: 1)
        case .last: jump(to: session.list.count - 1, direction: -1)
        case .delete: deleteCurrent()
        case .undo: undo()
        case .toggleZoom: toggleZoom()
        case .toggleInfo: setInfoVisible(!infoVisible)
        case .revealInFinder: revealInFinder()
        case .exit:
            view.exitZoom()
        }
    }

    func step(_ delta: Int, repeating isRepeat: Bool = false) {
        guard let index = session.list.index else { return }
        direction = delta < 0 ? -1 : 1
        repeating = isRepeat
        guard session.move(to: index + delta) else { return }
        didNavigate()
    }

    private func jump(to index: Int, direction: Int) {
        self.direction = direction
        repeating = false
        guard session.move(to: index) else { return }
        didNavigate()
    }

    func toggleZoom() {
        let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        view.toggleZoom(at: point.flatMap { view.bounds.contains($0) ? $0 : nil })
    }

    func deleteCurrent() {
        // Whatever is deleted must be what the user is looking at.
        guard let current = session.list.current, visiblePhoto == current else {
            NSSound.beep()
            return
        }
        // The next photo in the folder, unless the user asked to keep the direction of travel.
        if !Preferences.deleteFollowsDirection { direction = 1 }
        session.trashCurrent(direction: direction)
    }

    func undo() {
        if !session.undo() { NSSound.beep() }
    }

    func setInfoVisible(_ visible: Bool) {
        infoVisible = visible
        Preferences.infoVisible = visible
        updateInfo()
    }

    private func revealInFinder() {
        guard let current = session.list.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current.url])
    }

    // MARK: Window shape

    private func setWindowButtonsVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    /// Gives the window the photo's shape. A zoomed view keeps its window, so that comparing
    /// focus across photos does not move anything; leaving the zoom applies the shape.
    private func applyWindowShape(aspect: CGFloat) {
        if let shapedAspect, WindowShape.sameShape(shapedAspect, aspect) { return }
        if view.isZoomed { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        shapedAspect = aspect
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let frame = WindowShape.frame(aspect: aspect, height: chosenHeight, center: center, visible: screen.visibleFrame)
        window.contentAspectRatio = frame.size
        applyingShape = true
        window.setFrame(frame, display: false)
        applyingShape = false
    }

    // MARK: Navigation

    private func didNavigate() {
        navigationToken += 1
        settled = !repeating
        focused = false
        idle = false
        display()
        replan()
        scheduleTimers()
    }

    /// Later plans for when the user stays on this photo.
    private func scheduleTimers() {
        let token = navigationToken
        func after(_ delay: TimeInterval, _ change: @escaping @MainActor (ViewerController) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.navigationToken == token else { return }
                    change(self)
                    self.replan()
                }
            }
        }
        if repeating { after(0.12) { $0.settled = true } }
        after(0.5) { $0.focused = true }
        after(2) { $0.idle = true }
    }

    private func replan() {
        guard let index = session.list.index else { return }
        var input = PlanInput(count: session.list.count, current: index)
        input.direction = direction
        input.repeating = repeating
        input.settled = settled
        input.focused = focused
        input.zoomed = view.isZoomed
        input.idle = idle && Pipeline.canWorkInBackground
        pipeline.applyWindowSizes(to: &input)
        pipeline.plan(photos: session.list.photos, input: input)
    }

    // MARK: Display

    /// Shows the current photo's best frame, or nothing: never another photo's pixels.
    func display() {
        scheduleTitleUpdate()
        guard let current = session.list.current else {
            visiblePhoto = nil
            shownTier = nil
            view.showMessage(session.tombstones.isEmpty ? "Aucune photo" : "Aucune photo restante")
            updateInfo()
            onDisplayed?(PhotoKey(path: "", device: 0, inode: 0, size: 0, mtimeSeconds: 0, mtimeNanoseconds: 0), nil)
            return
        }
        if let frame = pipeline.cache.best(current, zoomed: view.isZoomed) {
            applyWindowShape(aspect: frame.nativeSize.width / frame.nativeSize.height)
            view.show(frame)
            visiblePhoto = current
            shownTier = frame.key.tier
        } else if pipeline.hasFailed(FrameKey(photo: current, tier: .screen)) {
            // Its name is on screen, so deleting it is still a clear choice.
            view.showMessage("Impossible de décoder \(current.name)")
            visiblePhoto = current
            shownTier = nil
        } else {
            view.showMessage(current.name)
            visiblePhoto = nil
            shownTier = nil
        }
        updateInfo()
        onDisplayed?(current, shownTier)
    }

    private func frameArrived(_ frame: Frame) {
        guard frame.key.photo == session.list.current else { return }
        if frame.key.tier == .full && !view.isZoomed && shownTier != nil { return }
        display()
    }

    private func frameFailed(_ key: FrameKey) {
        guard key.photo == session.list.current else { return }
        // A RAW that cannot render, or a file without preview before its render arrives.
        if key.tier == .screen { display() }
    }

    private func scheduleTitleUpdate() {
        guard !titlePending else { return }
        titlePending = true
        // Redrawing the title bar happens after the image, and at most once per turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.titlePending = false
                if let current = self.session.list.current, let index = self.session.list.index {
                    self.window.title = "\(current.name)   \(index + 1) / \(self.session.list.count)"
                } else {
                    self.window.title = "BetterView"
                }
            }
        }
    }

    /// The name and position are known at once; the shooting information follows, read ahead
    /// for the next photos so it is normally there on arrival.
    private func updateInfo() {
        guard infoVisible, let current = session.list.current, let index = session.list.index else {
            view.hideInfo()
            return
        }
        let known = metadata.metadata(for: current)
        view.setInfo(name: current.name, settings: known?.settingsText ?? "", date: known?.dateText ?? "", position: "\(index + 1) / \(session.list.count)")
        let photos = session.list.photos
        let around = [0, direction, 2 * direction, -direction, 3 * direction].compactMap { offset -> PhotoKey? in
            let at = index + offset
            return photos.indices.contains(at) ? photos[at] : nil
        }
        metadata.request(around)
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .listChanged:
            display()
            replan()
            scheduleTimers()
        case .restored:
            navigationToken += 1
            display()
            replan()
        case .trashed(let photo):
            pipeline.disk.invalidate(photo)
        case .fileChanged(let name):
            alert("\(name) a changé sur le disque", info: "La photo n'a pas été supprimée.")
        case .trashFailed(let photo, let message):
            confirmPermanentDelete(photo, message: message)
        case .restoreFailed(let name, let message):
            alert("Impossible de restaurer \(name)", info: "\(message)\nLe fichier est resté dans la corbeille.")
        case .deleteFailed(let name, let message):
            alert("Impossible de supprimer \(name)", info: message)
        }
    }

    private func alert(_ title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.beginSheetModal(for: window)
    }

    /// Volumes without a Trash: the file is kept unless the user confirms this one deletion.
    private func confirmPermanentDelete(_ photo: PhotoKey, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Impossible de mettre \(photo.name) à la corbeille"
        alert.informativeText = "\(message)\n\nLa suppression définitive ne pourra pas être annulée."
        alert.addButton(withTitle: "Conserver")
        alert.addButton(withTitle: "Supprimer définitivement").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertSecondButtonReturn { self?.session.deletePermanently(photo) }
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        session.requestScan()
        view.refreshHover()
    }

    /// A size the user chose stays for the next photos, whatever their orientation.
    func windowDidResize(_ notification: Notification) {
        guard !applyingShape else { return }
        chosenHeight = window.frame.height
    }
}
