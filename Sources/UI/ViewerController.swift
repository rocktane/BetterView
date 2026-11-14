import AppKit
import UniformTypeIdentifiers

/// Connects the session, the pipeline and the view. Navigation here does a cache lookup and
/// a layer commit, nothing else: all waiting happens in the pipeline.
@MainActor
final class ViewerController: NSObject, NSWindowDelegate {
    let session: LibrarySession
    let pipeline: Pipeline
    let view = ViewerView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
    let comparisonView = ComparisonView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
    private let strip = StripPanel()
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
    /// Zoomed through the AF command: each photo opens on its own AF position, at the
    /// current zoom, until the zoom ends.
    private(set) var followsFocus = false
    /// The photo last centred on its AF position, and whether that position was unknown.
    private var focusCentred: PhotoKey?
    private var focusAwaited = false
    /// The setting « Conserver le zoom en changeant de photo », off by default: then any change
    /// of photo goes back to the fit, AF mode included. Replaced by tests.
    var keepsZoomAcrossPhotos: () -> Bool = { Preferences.keepsZoomAcrossPhotos }
    /// The file last displayed: another one brings the zoom back to the fit.
    private var displayedPath: String?
    private var titlePending = false
    private let metadata = MetadataStore()
    private let thumbnails = ThumbnailStore()

    private var stripVisible = Preferences.stripVisible
    private var stripOtherOpacity = Float(Preferences.stripOtherOpacity)
    private var stripPending = false
    /// The photo a swipe brought to the middle of the strip, while the current photo is still
    /// the one given: any move of the current photo brings the strip back to it.
    private var stripBrowse: (center: PhotoKey, current: PhotoKey)?
    /// Photos picked to compare instead of the burst, or to delete together.
    private var selection = PhotoSelection()

    /// Set while comparing, when the comparison view has the window.
    private var comparison: ComparisonModel?
    /// What to give back on leaving: the comparison window has no photo's shape.
    private var preComparisonFrame: CGRect?
    private var preComparisonCenter: CGPoint?
    /// Slots whose content can legitimately be deleted: pixels, or an error with its name.
    private var comparedVisible: Set<Int> = []
    private let normalFullBudget: Int

    /// The shape the window currently has, and the size it keeps across shapes.
    private var shapedAspect: CGFloat?
    private var chosenHeight: CGFloat = 750
    private var applyingShape = false
    /// The centre shapes are placed around. Reading it back from the frame would add a
    /// rounding error at every change of orientation, and the window would creep sideways.
    private var shapeCenter: CGPoint?
    /// Set from the start of the way into full screen to the end of the way out: the window
    /// frame is the system's then, neither the photo's shape nor a size to keep.
    private var fullScreen = false
    /// The window's content in full screen: the photo above the strip.
    private(set) var fullScreenContainer: FullScreenContainer?
    /// Leaves full screen; replaced in tests, which must not take over the screen.
    lazy var leaveFullScreen: () -> Void = { [weak self] in self?.window.toggleFullScreen(nil) }
    /// The window has not shown a photo yet: it is small, and clicking it opens one.
    private var welcoming = false
    private static let welcomeSize = CGSize(width: 480, height: 300)

    /// Benchmark hooks.
    var onDisplayed: ((PhotoKey, Tier?) -> Void)?

    init(session: LibrarySession = LibrarySession(), diskDirectory: URL = DiskCache.defaultDirectory) {
        self.session = session
        let budget = Preferences.diskCacheBytes
        pipeline = Pipeline(
            budgets: .scaled(physicalMemory: ProcessInfo.processInfo.physicalMemory),
            disk: DiskCache(directory: diskDirectory, budget: budget)
        )
        normalFullBudget = pipeline.cache.budget(.full)
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
        // The green button goes full screen; Option-click keeps the standard zoom.
        window.collectionBehavior = .fullScreenPrimary
        window.minSize = NSSize(width: 200, height: 200)
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = view
        if !window.setFrameUsingName("Viewer") { window.center() }
        chosenHeight = window.frame.height
        // Small until a photo gives it its shape, around where the photos were last shown.
        // The size kept for photos is saved only from then on.
        shapeCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        welcoming = true
        window.setFrame(CGRect(
            x: (window.frame.midX - Self.welcomeSize.width / 2).rounded(),
            y: (window.frame.midY - Self.welcomeSize.height / 2).rounded(),
            width: Self.welcomeSize.width, height: Self.welcomeSize.height
        ), display: false)

        view.onCommand = { [weak self] in self?.handle($0) }
        comparisonView.onCommand = { [weak self] in self?.handle($0) }
        comparisonView.row.onClick = { [weak self] photo, _ in self?.comparisonRowClicked(photo) }
        strip.preferredScreen = { [weak self] in self?.window.screen }
        strip.onSizeChanged = { [weak self] in self?.scheduleStripUpdate() }
        strip.viewer = window
        strip.viewerFrame = { [weak self] in self?.stripHolderFrame }
        strip.view.onClick = { [weak self] photo, modifiers in self?.stripClicked(photo, modifiers: modifiers) }
        strip.view.onMenu = { [weak self] in self?.stripMenu(for: $0) }
        view.contextMenu = { [weak self] in self?.viewerMenu() }
        strip.view.onScroll = { [weak self] in self?.stripScrolled($0) }
        strip.view.onHoverChanged = { [weak self] in self?.view.refreshHover() }
        thumbnails.onLoaded = { [weak self] _ in self?.scheduleStripUpdate() }
        thumbnails.onStale = { [weak self] _ in self?.session.requestScan() }
        session.onEvent = { [weak self] in self?.handle($0) }
        pipeline.onFrame = { [weak self] in self?.frameArrived($0) }
        pipeline.onFailed = { [weak self] in self?.frameFailed($0) }
        pipeline.onStale = { [weak self] _ in self?.session.requestScan() }
        pipeline.onNeedsReplan = { [weak self] in self?.replan() }
        pipeline.onFocus = { [weak self] in self?.focusArrived($0) }
        pipeline.onEvicted = { [weak self] in
            if self?.comparison != nil { self?.displayComparison() }
        }
        metadata.onLoaded = { [weak self] photo in
            guard let self else { return }
            if self.comparison != nil {
                self.displayComparison()
                return
            }
            self.scheduleStripUpdate()
            if photo == self.session.list.current { self.updateInfo() }
        }

        updateTarget()
        pipeline.disk.load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        view.opensOnClick = true
        view.showMessage("Cliquer ou ⌘O pour ouvrir un dossier ou une photo")
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Same as ⌘O, attached to the viewer.
    func showOpenPanel() {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = RawFormat.all.compactMap { UTType($0.uti) } + [.folder]
        showWindow()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.open(panel.urls) }
            }
        }
    }

    func open(_ urls: [URL]) {
        leaveComparison()
        showWindow()
        visiblePhoto = nil
        selection.clear()
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
        refreshFullScreenScreen()
        strip.fitToScreen()
        if comparison != nil {
            placeComparisonWindow()
        } else {
            shapedAspect = nil
        }
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
        case .clicked: showOpenPanel()
        case .zoomChanged:
            if !view.isZoomed { stopFollowingFocus() }
            display()
            replan()
        case .selectSlot(let slot): selectSlot(slot)
        case .slotAction(let action, let slot, let photo): performOnSlot(action, slot: slot, photo: photo)
        }
    }

    func setShortcuts(_ map: ShortcutMap) {
        view.shortcuts = map
        comparisonView.shortcuts = map
        scheduleStripUpdate()
    }

    func perform(_ action: ShortcutAction, repeating isRepeat: Bool = false) {
        if comparison != nil {
            performInComparison(action)
            return
        }
        switch action {
        case .next: step(1, repeating: isRepeat)
        case .previous: step(-1, repeating: isRepeat)
        case .jumpForward: step(10, repeating: isRepeat)
        case .jumpBackward: step(-10, repeating: isRepeat)
        case .first: go(to: 0)
        case .last: go(to: session.list.count - 1)
        case .extendNext: extendSelection(by: 1, repeating: isRepeat)
        case .extendPrevious: extendSelection(by: -1, repeating: isRepeat)
        case .toggleSelection: toggleCurrentSelection()
        case .delete: deleteCurrent()
        case .undo: undo()
        case .toggleZoom: toggleZoom()
        case .zoomToFocus: zoomToFocus()
        case .zoomIn: view.stepZoom(by: 1, at: pointerInView())
        case .zoomOut: view.stepZoom(by: -1, at: pointerInView())
        case .zoomFit: view.exitZoom()
        case .toggleInfo: setInfoVisible(!infoVisible)
        case .revealInFinder: revealInFinder()
        case .exit:
            // Out of full screen only when there is nothing else to leave.
            let leavesSomething = !selection.isEmpty || view.isZoomed
            if !selection.isEmpty {
                selection.clear()
                scheduleStripUpdate()
            }
            view.exitZoom()
            if !leavesSomething, fullScreen { leaveFullScreen() }
        case .toggleStrip: setStripVisible(!stripVisible)
        case .compare: enterComparison()
        case .keepSelected: break
        }
    }

    func step(_ delta: Int, repeating isRepeat: Bool = false) {
        guard let index = session.list.index else { return }
        selection.endRun()
        direction = delta < 0 ? -1 : 1
        repeating = isRepeat
        guard session.move(to: index + delta) else { return }
        didNavigate()
    }

    private func jump(to index: Int, direction: Int) {
        selection.endRun()
        self.direction = direction
        repeating = false
        guard session.move(to: index) else { return }
        didNavigate()
    }

    private func go(to target: Int) {
        guard let index = session.list.index, target >= 0 else { return }
        jump(to: target, direction: target < index ? -1 : 1)
    }

    // MARK: Selection

    /// As ⇧→ in the Finder: moves on, and selects from where the run started to here,
    /// the photo left included.
    private func extendSelection(by delta: Int, repeating isRepeat: Bool) {
        guard let index = session.list.index else { return }
        let target = min(max(index + delta, 0), session.list.count - 1)
        selection.extend(from: index, to: target, in: session.list.photos)
        direction = delta < 0 ? -1 : 1
        repeating = isRepeat
        if session.move(to: target) {
            didNavigate()
        } else {
            scheduleStripUpdate()
        }
    }

    private func toggleCurrentSelection() {
        guard let current = session.list.current else { return }
        selection.toggle(current)
        scheduleStripUpdate()
    }

    func toggleZoom() {
        view.toggleZoom(at: pointerInView())
    }

    /// Where the pointer is over the photo, if it is: keyboard zooms start there.
    private func pointerInView() -> CGPoint? {
        let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        return point.flatMap { view.bounds.contains($0) ? $0 : nil }
    }

    /// Same key to leave: like Z, the zoom toggles.
    func zoomToFocus() {
        if followsFocus && view.isZoomed {
            view.exitZoom()
            return
        }
        guard session.list.current != nil else {
            NSSound.beep()
            return
        }
        followsFocus = true
        centreOnFocus(level: 1)
    }

    /// Centres the current photo on its AF position, or on the middle of the image when
    /// there is none, and says so: the zoom must not pretend to know where the focus is.
    private func centreOnFocus(level: CGFloat?) {
        guard let current = session.list.current else { return }
        focusCentred = current
        let focus = pipeline.cameraFocus(current)
        focusAwaited = focus == nil
        let middle = CGPoint(x: 0.5, y: 0.5)
        if case .point(let point) = focus {
            view.setFocusMarker(point.normalized, note: nil)
            view.zoom(onNormalized: point.normalized, level: level)
        } else {
            view.setFocusMarker(nil, note: Self.focusNote(focus))
            view.zoom(onNormalized: middle, level: level)
        }
    }

    /// Said when the zoom falls back on the middle: it must not pretend to know the focus.
    private static func focusNote(_ focus: CameraFocus?) -> String? {
        switch focus {
        case .manual: "Mise au point manuelle : centre"
        case .absent: "Pas de point AF : centre"
        case .point, nil: nil
        }
    }

    private func stopFollowingFocus() {
        guard followsFocus else { return }
        followsFocus = false
        focusCentred = nil
        focusAwaited = false
        view.setFocusMarker(nil, note: nil)
    }

    /// The header was read after the photo appeared: move to it, unless the user has
    /// started looking around on their own.
    private func focusArrived(_ photo: PhotoKey) {
        if let comparison {
            if comparisonView.followsFocus, comparison.shown.contains(photo) { displayComparison() }
            return
        }
        guard followsFocus, focusAwaited, photo == session.list.current, photo == focusCentred else { return }
        if view.movedByUser {
            focusAwaited = false
            return
        }
        centreOnFocus(level: nil)
    }

    func deleteCurrent() {
        let selected = selection.photos(in: session.list.photos)
        if selected.count > 1 {
            deleteSelection(selected)
            return
        }
        trashCurrentPhoto()
    }

    private func trashCurrentPhoto() {
        // Whatever is deleted must be what the user is looking at.
        guard let current = session.list.current, visiblePhoto == current else {
            NSSound.beep()
            return
        }
        // Known protected (camera « Protéger », Finder lock, read-only): refused at once, no queue.
        let protection = session.protection(of: current)
        guard protection.isEmpty else {
            view.flash(protection.refusal)
            return
        }
        // The next photo in the folder, unless the user asked to keep the direction of travel.
        if !Preferences.deleteFollowsDirection { direction = 1 }
        session.trashCurrent(direction: direction)
    }

    /// Several selected photos go together, as one gesture for ⌘Z. They are not all on
    /// screen, so the user confirms first, unless they chose not to be asked. The context
    /// menu also sends here a thumbnail that is not the photo shown, `isSelection` false.
    private func deleteSelection(_ photos: [PhotoKey], isSelection: Bool = true) {
        guard window.attachedSheet == nil else { return }
        let deletable = photos.filter { session.protection(of: $0).isEmpty }
        let kept = photos.count - deletable.count
        guard !deletable.isEmpty else {
            view.flash(kept > 1 ? "Photos protégées : suppression refusée" : "Photo protégée : suppression refusée")
            return
        }
        let count = deletable.count
        var message = "\(count) photo\(count > 1 ? "s" : "") à la corbeille"
        if kept > 0 { message += "  ·  \(kept) protégée\(kept > 1 ? "s" : "") conservée\(kept > 1 ? "s" : "")" }
        let trash = { [weak self] in
            guard let self else { return }
            guard self.session.trash(deletable) else {
                NSSound.beep()
                self.session.requestScan()
                return
            }
            if isSelection { self.selection.clear() }
            self.scheduleStripUpdate()
            let undoKey = self.view.shortcuts.keys(for: .undo).first?.label
            self.view.flash(undoKey.map { "\(message)  ·  \($0) pour annuler" } ?? message)
        }
        guard Preferences.confirmsMultipleDelete else {
            trash()
            return
        }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Mettre \(deletable[0].name) à la corbeille ?" : "Mettre \(count) photos à la corbeille ?"
        var info = switch (isSelection, count) {
        case (_, 1): "Ce n'est pas la photo affichée."
        case (true, _): "Les photos sélectionnées ne sont pas toutes à l'écran. Une seule annulation les remettra toutes."
        case (false, _): "Ces photos ne sont pas toutes à l'écran. Une seule annulation les remettra toutes."
        }
        if kept > 0 { info += "\n\n\(kept) photo\(kept > 1 ? "s protégées restent" : " protégée reste") dans le dossier." }
        alert.informativeText = info
        alert.addButton(withTitle: "Mettre à la corbeille")
        alert.addButton(withTitle: "Annuler")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Ne plus demander"
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                if alert.suppressionButton?.state == .on { Preferences.confirmsMultipleDelete = false }
                trash()
            }
        }
    }

    func undo() {
        if !session.undo() { NSSound.beep() }
    }

    func setInfoVisible(_ visible: Bool) {
        infoVisible = visible
        Preferences.infoVisible = visible
        updateInfo()
    }

    func setStripVisible(_ visible: Bool) {
        stripVisible = visible
        Preferences.stripVisible = visible
        updateStrip()
    }

    private func revealInFinder() {
        guard let current = session.list.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current.url])
    }

    // MARK: Window shape

    /// A size picked in the settings, applied at once; custom brings back the size stretched.
    func setStripSizePreset(_ preset: StripSizePreset) {
        strip.applySize(preset.size ?? Preferences.stripSize ?? .standard)
    }

    func setStripOtherOpacity(_ opacity: Double) {
        stripOtherOpacity = Float(opacity)
        updateStrip()
    }

    private func setWindowButtonsVisible(_ visible: Bool) {
        // In full screen the system shows and hides the title bar itself: the buttons must be
        // there when it does.
        let visible = visible || fullScreen
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.fade(visible: visible)
        }
    }

    /// Gives the window the photo's shape. A zoomed view keeps its window, so that comparing
    /// focus across photos does not move anything; leaving the zoom applies the shape.
    ///
    /// A preview's size comes from the file header, slightly off the rendered one, so it keeps
    /// a window that is nearly right: the window does not shake while a key is held. A
    /// rendered frame always gets its exact shape, so no photo stays cropped.
    private func applyWindowShape(aspect: CGFloat, approximate: Bool) {
        if approximate, let shapedAspect, WindowShape.sameShape(shapedAspect, aspect) { return }
        if view.isZoomed { return }
        if fullScreen {
            // The screen is the window: the photo's view takes the shape instead.
            shapedAspect = aspect
            fullScreenContainer?.photoAspect = aspect
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        shapedAspect = aspect
        let center = shapeCenter ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        shapeCenter = center
        let frame = WindowShape.frame(aspect: aspect, height: chosenHeight, center: center, visible: screen.visibleFrame)
        // Also after a launch, when the restored frame may already have this size.
        window.contentAspectRatio = frame.size
        guard frame.size != window.frame.size || welcoming else { return }
        applyingShape = true
        window.setFrame(frame, display: false)
        applyingShape = false
        if welcoming {
            welcoming = false
            window.setFrameAutosaveName("Viewer")
        }
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
        if let comparison {
            input.comparison = comparisonPlan(comparison)
            input.zoomed = comparisonView.zoom != nil
            input.memory = pipeline.memoryLevel
            pipeline.plan(photos: session.list.photos, input: input)
            return
        }
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
        if comparison != nil {
            displayComparison()
            return
        }
        scheduleTitleUpdate()
        let photoChanged = session.list.current?.path != displayedPath
        displayedPath = session.list.current?.path
        if view.isZoomed {
            if photoChanged && !keepsZoomAcrossPhotos() {
                // Each photo opens fitted, in its own window shape.
                stopFollowingFocus()
                view.resetZoom()
            } else if followsFocus, let current = session.list.current, current != focusCentred {
                // Kept on purpose: each photo opens on its own AF position, at the same zoom.
                centreOnFocus(level: nil)
            }
        }
        scheduleStripUpdate()
        view.opensOnClick = session.list.current == nil
        guard let current = session.list.current else {
            visiblePhoto = nil
            shownTier = nil
            view.showMessage(session.tombstones.isEmpty ? "Aucune photo" : "Aucune photo restante")
            updateInfo()
            view.setProtected(false)
            onDisplayed?(PhotoKey(path: "", device: 0, inode: 0, size: 0, mtimeSeconds: 0, mtimeNanoseconds: 0), nil)
            return
        }
        if let frame = pipeline.cache.best(current, zoomed: view.isZoomed) {
            applyWindowShape(aspect: frame.nativeSize.width / frame.nativeSize.height, approximate: frame.key.tier == .preview)
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
        updateProtectionBadge()
        updateInfo()
        onDisplayed?(current, shownTier)
    }

    /// After the image commit: one dictionary lookup, no I/O.
    private func updateProtectionBadge() {
        view.setProtected(session.list.current.map { !session.protection(of: $0).isEmpty } ?? false)
    }

    private func frameArrived(_ frame: Frame) {
        if let comparison {
            if comparison.shown.contains(frame.key.photo) { displayComparison() }
            return
        }
        guard frame.key.photo == session.list.current else { return }
        if frame.key.tier == .full && !view.isZoomed && shownTier != nil { return }
        display()
    }

    private func frameFailed(_ key: FrameKey) {
        if let comparison {
            if comparison.shown.contains(key.photo) { displayComparison() }
            return
        }
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
        requestMetadata()
        guard infoVisible, let current = session.list.current, let index = session.list.index else {
            view.hideInfo()
            return
        }
        let known = metadata.metadata(for: current)
        view.setInfo(name: current.name, settings: known?.settingsText ?? "", date: known?.dateText ?? "", position: "\(index + 1) / \(session.list.count)")
    }

    /// The nearest photos first, then enough around them to see the bursts. A held key only
    /// asks for the nearest: the rest would be out of date at the next repeat.
    private func requestMetadata() {
        guard let index = session.list.index else { return }
        let photos = session.list.photos
        var offsets = [0, direction, 2 * direction, -direction, 3 * direction]
        if !repeating {
            for distance in 1...Self.burstReach {
                offsets.append(distance * direction)
                offsets.append(-distance * direction)
            }
        }
        var positions = offsets.map { index + $0 }
        // A strip browsed elsewhere also needs the dates that outline its bursts. One request
        // for both: each replaces the last.
        if let center = browsedIndex() {
            positions += [center] + (1...Self.burstReach).flatMap { [center + $0, center - $0] }
        }
        var seen = Set<Int>()
        metadata.request(positions.compactMap { at -> PhotoKey? in
            photos.indices.contains(at) && seen.insert(at).inserted ? photos[at] : nil
        })
    }

    // MARK: Strip

    /// How far from the current photo a burst is looked for: this bounds a comparison's size too.
    private static let burstReach = 12

    /// Drawn after the image, and at most once per turn: the strip never delays a photo.
    private func scheduleStripUpdate() {
        guard !stripPending else { return }
        stripPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stripPending = false
                self.updateStrip()
            }
        }
    }

    /// The photo or the comparison, in the window or, in full screen, above the strip.
    private func setContent(_ content: NSView) {
        if let fullScreenContainer {
            fullScreenContainer.content = content
            fullScreenContainer.photoAspect = content === view ? shapedAspect : nil
            updateFullScreenRoom()
        } else {
            window.contentView = content
        }
    }

    /// The strip's room at the bottom in full screen: its height when it is wanted there,
    /// whether the app is active or not, so that switching apps does not move the photo.
    private func updateFullScreenRoom() {
        guard let fullScreenContainer, let screen = strip.fullScreenFrame else { return }
        let wanted = comparison == nil && stripVisible && session.list.count > 1 && session.list.index != nil
        fullScreenContainer.bottomInset = wanted ? strip.fullScreenHeight(on: screen) : 0
    }

    private func updateStrip() {
        updateFullScreenRoom()
        guard comparison == nil else {
            strip.setVisible(false)
            updateComparisonRow()
            return
        }
        guard stripVisible, window.isVisible, !window.isMiniaturized,
              session.list.count > 1, let index = session.list.index
        else {
            strip.setVisible(false)
            return
        }
        strip.setVisible(true)
        // Also after the first shape, given while the window was still the welcome one.
        strip.followViewer()
        let photos = session.list.photos
        let center = browsedIndex() ?? index
        // More than the strip can show even with portrait photos: it cuts the rest at its edges.
        let stripReach = max(Self.stripReach, strip.reach)
        let shown = StripView.window(around: center, count: photos.count, reach: stripReach)
        let cells = shown.map { at -> StripCell in
            let photo = photos[at]
            let selected = selection.contains(photo)
            return StripCell(
                photo: photo,
                image: thumbnails.image(for: photo),
                mark: at == index ? .current : .none,
                selected: selected,
                opacity: at == index || selected ? 1 : stripOtherOpacity
            )
        }
        // Nearest first, and beyond the edges, so that moving along finds them ready.
        let ahead = (1...(2 * stripReach + Self.thumbnailMargin)).flatMap { [center + $0 * direction, center - $0 * direction] }
        let wanted = ([center] + ahead).filter { photos.indices.contains($0) && ($0 - center).magnitude <= stripReach + Self.thumbnailMargin || shown.contains($0) }
        thumbnails.pixels = strip.thumbnailPixels
        thumbnails.request(wanted.map { photos[$0] })

        let reach = max(center - Self.burstReach, 0)...min(center + Self.burstReach, photos.count - 1)
        let bursts = PhotoGroups.bursts(dates: photos[reach].map { metadata.metadata(for: $0)?.date })
            .map { ($0.lowerBound + reach.lowerBound)...($0.upperBound + reach.lowerBound) }
        // Positions among the cells, cut to what they cover.
        func cellRange(_ burst: ClosedRange<Int>) -> ClosedRange<Int>? {
            let from = max(burst.lowerBound, shown.lowerBound), to = min(burst.upperBound, shown.upperBound)
            return from <= to ? (from - shown.lowerBound)...(to - shown.lowerBound) : nil
        }
        let compareKey = view.shortcuts.keys(for: .compare).first?.label
        var groups: [ClosedRange<Int>] = []
        var tips: [String] = []
        for burst in bursts {
            guard let range = cellRange(burst) else { continue }
            groups.append(range)
            tips.append("Rafale de \(burst.count)" + (compareKey.map { "  ·  \($0) pour comparer" } ?? ""))
        }
        strip.view.update(
            cells: cells, anchor: center - shown.lowerBound,
            cut: (shown.lowerBound > 0, shown.upperBound < photos.count - 1),
            groups: groups, tips: tips, selecting: showsSelectionRings
        )
    }

    /// The rings show while a photo of the folder is checked: a checked photo deleted or gone
    /// from the folder no longer counts. Nothing to look through when nothing is checked.
    private var showsSelectionRings: Bool {
        !selection.isEmpty && session.list.photos.contains(where: selection.contains)
    }

    /// Where the strip was swiped to, if the current photo has not moved since.
    private func browsedIndex() -> Int? {
        guard let browse = stripBrowse, browse.current == session.list.current,
              let at = session.list.photos.firstIndex(of: browse.center)
        else {
            stripBrowse = nil
            return nil
        }
        return at
    }

    /// A swipe along the strip only browses it: the current photo stays.
    private func stripScrolled(_ delta: Int) {
        defer { scheduleStripUpdate() }
        let photos = session.list.photos
        guard let current = session.list.current, let index = session.list.index else { return }
        let center = browsedIndex() ?? index
        let target = min(max(center + delta, 0), photos.count - 1)
        stripBrowse = target == index ? nil : (photos[target], current)
        requestMetadata()
    }

    private static let stripReach = 14
    private static let thumbnailMargin = 6

    /// As in the Finder: Shift selects up to the thumbnail, Command adds or removes it.
    /// Neither changes the photo shown; a plain click goes to it.
    private func stripClicked(_ photo: PhotoKey, modifiers: NSEvent.ModifierFlags) {
        let photos = session.list.photos
        guard let at = photos.firstIndex(of: photo), let index = session.list.index else { return }
        if modifiers.contains(.command) {
            selection.toggle(photo)
            updateStrip()
        } else if modifiers.contains(.shift) {
            selection.extend(from: index, to: at, in: photos)
            updateStrip()
        } else if at != index {
            jump(to: at, direction: at < index ? -1 : 1)
        }
    }

    // MARK: Context menu

    private func viewerMenu() -> NSMenu? {
        guard comparison == nil, let current = session.list.current, visiblePhoto == current else { return nil }
        return contextMenu(for: current)
    }

    private func stripMenu(for photo: PhotoKey) -> NSMenu? {
        comparison == nil ? contextMenu(for: photo) : nil
    }

    /// The same menu on the photo and on its thumbnail. As in the Finder, it acts on the
    /// selection when the photo belongs to it; the selection and the folder, when they are
    /// more, get their own Lightroom items.
    private func contextMenu(for clicked: PhotoKey) -> NSMenu {
        let photos = session.list.photos
        let selected = selection.photos(in: photos)
        let target = PhotoMenuTarget(clicked: clicked, selection: selected, folder: photos)
        let count = target.photos.count
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, image: NSImage? = nil, _ handler: @escaping @MainActor (ViewerController) -> Void) {
            menu.addItem(ClosureMenuItem(title, image: image) { [weak self] in
                if let self { handler(self) }
            })
        }

        let lightroom = ExternalApps.lightroom()
        if let lightroom {
            let icon = ExternalApps.icon(of: lightroom)
            add(PhotoMenuTarget.openTitle(app: lightroom.name, count: count, selected: target.isSelection), image: icon) {
                $0.confirmOpen(target.photos, in: lightroom)
            }
            if !target.otherSelection.isEmpty {
                add(PhotoMenuTarget.openTitle(app: lightroom.name, count: target.otherSelection.count, selected: true), image: icon) {
                    $0.confirmOpen(target.otherSelection, in: lightroom)
                }
            }
            if !target.folder.isEmpty {
                add(PhotoMenuTarget.openTitle(app: lightroom.name, count: target.folder.count, folder: true), image: icon) {
                    $0.confirmOpen(target.folder, in: lightroom)
                }
            }
        }
        let apps = ExternalApps.apps(opening: clicked.url).filter { $0.url != lightroom?.url }
        if !apps.isEmpty {
            let submenu = NSMenu()
            for app in apps {
                submenu.addItem(ClosureMenuItem(app.name, image: ExternalApps.icon(of: app)) { [weak self] in
                    self?.openPhotos(target.photos, in: app)
                })
            }
            let openWith = NSMenuItem(title: "Ouvrir avec", action: nil, keyEquivalent: "")
            openWith.submenu = submenu
            menu.addItem(openWith)
        }

        menu.addItem(.separator())
        let urls = target.photos.map(\.url)
        add(count == 1 ? "Afficher dans le Finder" : "Afficher les \(count) photos dans le Finder") { _ in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        add(count == 1 ? "Copier" : "Copier les \(count) photos") { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
        menu.addItem(NSSharingServicePicker(items: urls).standardShareMenuItem)

        menu.addItem(.separator())
        add(selection.contains(clicked) ? "Désélectionner" : "Sélectionner") {
            $0.selection.toggle(clicked)
            $0.updateStrip()
        }
        if !selected.isEmpty {
            add("Tout désélectionner") {
                $0.selection.clear()
                $0.updateStrip()
            }
        }
        if count >= 2 {
            add("Comparer les \(count) photos") { $0.enterComparison(target.photos) }
        }

        menu.addItem(.separator())
        add(count == 1 ? "Mettre à la corbeille" : "Mettre les \(count) photos à la corbeille") {
            $0.trashFromMenu(target.photos, isSelection: target.isSelection)
        }
        return menu
    }

    private func trashFromMenu(_ photos: [PhotoKey], isSelection: Bool) {
        if photos.count == 1, photos[0] == session.list.current {
            trashCurrentPhoto()
        } else {
            deleteSelection(photos, isSelection: isSelection)
        }
    }

    /// Always asked, even for one photo: sending a folder to a catalog by mistake is
    /// tedious to undo there.
    private func confirmOpen(_ photos: [PhotoKey], in app: ExternalApps.App) {
        guard !photos.isEmpty, window.attachedSheet == nil else { return }
        let one = photos.count == 1
        let alert = NSAlert()
        alert.messageText = one ? "Ouvrir \(photos[0].name) dans \(app.name) ?" : "Ouvrir \(photos.count) photos dans \(app.name) ?"
        alert.informativeText = app.importsFirst
            ? "\(app.name) \(one ? "la" : "les") proposera dans sa fenêtre d'importation : rien n'entre dans le catalogue avant d'y cliquer sur Importer."
            : "\(app.name) va s'ouvrir avec \(one ? "cette photo" : "ces photos")."
        alert.addButton(withTitle: "Ouvrir")
        alert.addButton(withTitle: "Annuler")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.openPhotos(photos, in: app)
            }
        }
    }

    private func openPhotos(_ photos: [PhotoKey], in app: ExternalApps.App) {
        ExternalApps.open(photos, with: app) { [weak self] message in
            self?.alert("Impossible d'ouvrir les photos dans \(app.name)", info: message)
        }
    }

    // MARK: Comparison

    /// The Shift-clicked photos, or else the burst around the current photo, or else the
    /// current photo and the next.
    private func photosToCompare() -> [PhotoKey] {
        let picked = selection.photos(in: session.list.photos)
        if picked.count >= 2 { return picked }
        guard let index = session.list.index else { return [] }
        let photos = session.list.photos
        let reach = max(index - Self.burstReach, 0)...min(index + Self.burstReach, photos.count - 1)
        let bursts = PhotoGroups.bursts(dates: photos[reach].map { metadata.metadata(for: $0)?.date })
        if let burst = bursts.first(where: { $0.contains(index - reach.lowerBound) }) {
            return Array(photos[(burst.lowerBound + reach.lowerBound)...(burst.upperBound + reach.lowerBound)])
        }
        guard photos.count >= 2 else { return [] }
        return index + 1 < photos.count ? [photos[index], photos[index + 1]] : [photos[index - 1], photos[index]]
    }

    private func enterComparison(_ photos: [PhotoKey]? = nil) {
        guard let model = ComparisonModel(photos: photos ?? photosToCompare(), focusing: session.list.current) else {
            NSSound.beep()
            return
        }
        view.exitZoom()
        preComparisonFrame = window.frame
        preComparisonCenter = shapeCenter ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        // The large window must not come back as the viewer's at the next launch.
        window.setFrameAutosaveName("")
        comparison = model
        selection.clear()
        strip.setVisible(false)
        comparedVisible = []
        comparisonView.reset()
        // The viewer leaves the window: it must not keep a surface alive that the cache let go.
        view.showMessage(nil)
        visiblePhoto = nil
        comparisonView.frame = window.contentLayoutRect
        setContent(comparisonView)
        window.makeFirstResponder(comparisonView)
        setWindowButtonsVisible(true)
        // Four photos at 100 % have to fit at once, or each render would push another out.
        pipeline.cache.setBudget(.full, normalFullBudget * 2)
        // Any size goes while comparing.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        placeComparisonWindow()
        syncListToFocus()
        displayComparison()
        replan()
    }

    /// Close to the whole screen: this is the one view that wants the room.
    private func placeComparisonWindow() {
        guard !fullScreen, let screen = window.screen ?? NSScreen.main else { return }
        applyingShape = true
        window.setFrame(screen.visibleFrame.insetBy(dx: 16, dy: 12), display: true)
        applyingShape = false
    }

    /// Back to the viewer, on the focused photo, with the window it had.
    private func leaveComparison() {
        guard comparison != nil else { return }
        syncListToFocus()
        comparison = nil
        comparisonView.reset()
        pipeline.cache.setBudget(.full, normalFullBudget)
        applyingShape = true
        setContent(view)
        // In full screen, the way out gives the window back; the shape follows then.
        if !fullScreen {
            if let preComparisonFrame { window.setFrame(preComparisonFrame, display: true) }
            window.contentAspectRatio = preComparisonFrame?.size ?? window.frame.size
        }
        applyingShape = false
        // Without a photo shown yet, the first shape enables it: the small frame is not kept.
        // Nor the screen's, in full screen: the way out enables it.
        if !welcoming, !fullScreen { window.setFrameAutosaveName("Viewer") }
        window.makeFirstResponder(view)
        shapeCenter = preComparisonCenter
        shapedAspect = nil
        view.refreshHover()
        setWindowButtonsVisible(view.isHovered)
        didNavigate()
    }

    private func comparisonPlan(_ model: ComparisonModel) -> ComparisonPlan {
        var positions: [String: Int] = [:]
        for (at, photo) in session.list.photos.enumerated() { positions[photo.path] = at }
        var shown = model.shown.filter { $0 != model.focused }
        if let focused = model.focused { shown.insert(focused, at: 0) }
        return ComparisonPlan(
            shown: shown.compactMap { positions[$0.path] },
            waiting: model.waiting.compactMap { positions[$0.path] }
        )
    }

    /// Everything else in the app reads the current photo: it follows the focus.
    private func syncListToFocus() {
        guard let focused = comparison?.focused, let at = session.list.photos.firstIndex(of: focused) else { return }
        session.move(to: at)
    }

    private func displayComparison() {
        guard let model = comparison else { return }
        comparisonView.arrange(layout: model.layout, focus: model.focus, photos: model.slots)
        let left = model.remaining
        comparisonView.setTitle("Comparer  ·  \(left) photo\(left > 1 ? "s" : "") restante\(left > 1 ? "s" : "")")
        comparedVisible = []
        let zoomed = comparisonView.zoom
        let followsFocus = comparisonView.followsFocus
        for (slot, entry) in model.slots.enumerated() {
            guard let photo = entry else {
                comparisonView.setFocus(nil, photo: nil, slot: slot)
                continue
            }
            let known = metadata.metadata(for: photo)
            let locked = !session.protection(of: photo).isEmpty
            let note: String?
            if followsFocus {
                let focus = pipeline.cameraFocus(photo)
                comparisonView.setFocus(focus, photo: photo, slot: slot)
                note = Self.focusNote(focus)
            } else {
                note = nil
            }
            // The AF note stays on every state of the slot, next to the protection.
            func badge(_ text: String?, locked: Bool) -> String? {
                let parts = [text, note].compactMap { $0 }
                return Self.badge(parts.isEmpty ? nil : parts.joined(separator: "  ·  "), locked: locked)
            }
            comparisonView.setCaption(slot: slot, number: slot + 1, name: photo.name, settings: known?.settingsText ?? "")
            if let frame = pipeline.cache.best(photo, zoomed: zoomed != nil) {
                comparisonView.showFrame(frame, slot: slot)
                comparedVisible.insert(slot)
                if frame.key.tier == .preview {
                    comparisonView.setBadge(badge("Aperçu", locked: locked), slot: slot)
                } else if let zoomed {
                    // Under memory pressure, only the focused photo is rendered at 100 %.
                    let coming = pipeline.memoryLevel == .normal || slot == model.focus
                    comparisonView.setBadge(badge(frame.key.tier == .full ? "\(Int((zoomed * 100).rounded())) %" : (coming ? "Rendu 100 %…" : nil), locked: locked), slot: slot)
                } else {
                    comparisonView.setBadge(badge(nil, locked: locked), slot: slot)
                }
            } else if pipeline.hasFailed(FrameKey(photo: photo, tier: .screen)) {
                comparisonView.showMessage("Impossible de décoder \(photo.name)", slot: slot)
                comparisonView.setBadge(badge(nil, locked: locked), slot: slot)
                comparedVisible.insert(slot)
            } else {
                comparisonView.showMessage(photo.name, slot: slot)
                comparisonView.setBadge(badge(nil, locked: locked), slot: slot)
            }
        }
        metadata.request(model.shown + model.waiting.prefix(ComparisonModel.slotCount))
        scheduleStripUpdate()
    }

    /// A protected photo says so on its badge, next to what the badge already shows.
    private static func badge(_ text: String?, locked: Bool) -> String? {
        guard locked else { return text }
        return text.map { "\($0)  ·  Protégée" } ?? "Protégée"
    }

    /// Every photo of the comparison: its slot number shows through the marks and the opacity.
    private func updateComparisonRow() {
        guard let model = comparison else { return }
        let members = model.members
        // Its own size, smaller than a stretched strip's: a large group stays within budget.
        thumbnails.pixels = ThumbnailStore.pixels(forHeight: comparisonView.row.metrics.height, scale: window.backingScaleFactor)
        thumbnails.request(members)
        let cells = members.map { photo -> StripCell in
            let inSlot = model.shown.contains(photo)
            let isWaiting = model.waiting.contains(photo)
            return StripCell(
                photo: photo,
                image: thumbnails.image(for: photo),
                mark: photo == model.focused ? .current : .none,
                opacity: inSlot ? 1 : (isWaiting ? 0.45 : 0.14)
            )
        }
        let waiting = model.waiting.count
        // Centred when it fits; a long burst keeps the focused photo in the middle instead.
        comparisonView.row.update(cells: cells, anchor: model.focused.flatMap { members.firstIndex(of: $0) })
        comparisonView.setRowNote(waiting > 0 ? "\(waiting) en attente" : nil)
    }

    private func comparisonRowClicked(_ photo: PhotoKey) {
        guard let slot = comparison?.slots.firstIndex(of: photo) else { return }
        selectSlot(slot)
    }

    private func selectSlot(_ slot: Int) {
        comparison?.setFocus(slot: slot)
        focusChanged()
    }

    /// A button over a photo: that photo takes the focus, then the action runs with the
    /// guards of the keyboard. Nothing happens if the slot no longer shows that photo.
    private func performOnSlot(_ action: ShortcutAction, slot: Int, photo: PhotoKey?) {
        guard let model = comparison, photo != nil, model.slots.indices.contains(slot), model.slots[slot] == photo else {
            NSSound.beep()
            return
        }
        if model.focus != slot { selectSlot(slot) }
        guard comparison?.focus == slot else { return }
        performInComparison(action)
    }

    private func focusChanged() {
        syncListToFocus()
        displayComparison()
        replan()
    }

    private func performInComparison(_ action: ShortcutAction) {
        guard comparison != nil else { return }
        switch action {
        case .next, .jumpForward:
            comparison?.moveFocus(by: 1)
            focusChanged()
        case .previous, .jumpBackward:
            comparison?.moveFocus(by: -1)
            focusChanged()
        case .delete:
            trashFocusedInComparison()
        case .keepSelected:
            keepFocusedInComparison()
        case .undo:
            undo()
        case .toggleZoom:
            let point = window.mouseLocationOutsideOfEventStream
            comparisonView.toggleZoom(atWindowPoint: comparisonView.bounds.contains(comparisonView.convert(point, from: nil)) ? point : nil)
        case .exit:
            if comparisonView.zoom != nil {
                comparisonView.exitZoom()
            } else {
                leaveComparison()
            }
        case .compare:
            leaveComparison()
        case .revealInFinder:
            revealInFinder()
        case .zoomToFocus:
            // Same key to leave, as in the viewer.
            if comparisonView.followsFocus {
                comparisonView.exitZoom()
            } else {
                comparisonView.zoomOnFocus()
                displayComparison()
            }
        case .toggleInfo, .toggleStrip, .first, .last, .extendNext, .extendPrevious,
             .toggleSelection, .zoomIn, .zoomOut, .zoomFit:
            break
        }
    }

    /// Whatever is deleted must be what the user is looking at.
    private func trashFocusedInComparison() {
        guard let model = comparison, let focused = model.focused, comparedVisible.contains(model.focus) else {
            NSSound.beep()
            return
        }
        let protection = session.protection(of: focused)
        guard protection.isEmpty else {
            comparisonView.showToast(protection.refusal)
            return
        }
        trashInComparison([focused], message: "\(focused.name) à la corbeille")
    }

    /// Removes the other photos on screen. Those still waiting stay out of this: nobody has
    /// seen them yet. They come in next.
    private func keepFocusedInComparison() {
        guard let model = comparison, model.focused != nil else { return }
        let others = model.shownOthers
        let everyoneVisible = model.slots.indices.allSatisfy { model.slots[$0] == nil || comparedVisible.contains($0) }
        guard !others.isEmpty, everyoneVisible else {
            NSSound.beep()
            return
        }
        // Protected photos stay on screen: keeping one photo never deletes a protected one.
        let deletable = others.filter { session.protection(of: $0).isEmpty }
        let kept = others.count - deletable.count
        guard !deletable.isEmpty else {
            comparisonView.showToast(kept > 1 ? "Photos protégées : non supprimées" : "Photo protégée : non supprimée")
            return
        }
        let count = deletable.count
        var message = "\(count) photo\(count > 1 ? "s" : "") à la corbeille"
        if kept > 0 { message += "  ·  \(kept) protégée\(kept > 1 ? "s" : "") conservée\(kept > 1 ? "s" : "")" }
        trashInComparison(deletable, message: message)
    }

    private func trashInComparison(_ photos: [PhotoKey], message: String) {
        // The model first: the list event that follows must find them already gone from it.
        comparison?.remove(photos)
        guard session.trash(photos) else {
            NSSound.beep()
            comparisonListChanged()
            session.requestScan()
            return
        }
        if comparison != nil {
            let undoKey = view.shortcuts.keys(for: .undo).first?.label
            comparisonView.showToast(undoKey.map { "\(message)  ·  \($0) pour annuler" } ?? message)
        }
    }

    /// The list changed under the comparison: a deletion just made, or the folder itself.
    private func comparisonListChanged() {
        comparison?.reconcile(with: session.list.photos)
        guard let model = comparison else { return }
        if model.remaining <= 1 {
            leaveComparison()
            return
        }
        focusChanged()
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .listChanged:
            if comparison != nil {
                comparisonListChanged()
                return
            }
            display()
            replan()
            scheduleTimers()
        case .restored:
            navigationToken += 1
            if comparison != nil {
                // Its list event already brought the photo back; the session then selected it.
                focusChanged()
                return
            }
            display()
            replan()
        case .trashed(let photo):
            pipeline.disk.invalidate(photo)
        case .fileChanged(let name):
            alert("\(name) a changé sur le disque", info: "La photo n'a pas été supprimée.")
        case .protectionChanged:
            if comparison != nil { displayComparison() } else { updateProtectionBadge() }
        case .trashFailed(let photo, let failure):
            if failure.allowsPermanentDelete {
                confirmPermanentDelete(photo, message: failure.explanation)
            } else {
                alert("\(photo.name) n'a pas été mise à la corbeille", info: failure.explanation)
            }
        case .restoreFailed(let name, let message):
            // Restores also start from the history window: the alert goes where the user is.
            alert("Impossible de restaurer \(name)", info: message, in: NSApp.keyWindow)
        case .deleteFailed(let name, let message):
            alert("Impossible de supprimer \(name)", info: message)
        case .historyNotSaved(let message):
            alert("L'historique des suppressions n'est pas enregistré", info: "\(message)\n\nLes suppressions continuent de fonctionner et ⌘Z reste possible, mais elles n'apparaîtront plus dans l'historique après avoir quitté.")
        }
    }

    private func alert(_ title: String, info: String, in host: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let target = host.flatMap { $0.attachedSheet == nil && !($0 is NSPanel) ? $0 : nil } ?? window
        alert.beginSheetModal(for: target)
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
                guard response == .alertSecondButtonReturn else { return }
                // Recorded like a trash, so a failure brings the photo back to its slot.
                self?.comparison?.remove([photo])
                self?.session.deletePermanently(photo)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        session.requestScan()
        if comparison != nil { comparisonView.refreshHover() } else { view.refreshHover() }
    }

    /// The window's frame while it can hold the strip: a photo's shape, on screen.
    private var stripHolderFrame: CGRect? {
        guard window.isVisible, !window.isMiniaturized, comparison == nil, !welcoming else { return nil }
        return window.frame
    }

    func windowWillClose(_ notification: Notification) { strip.setVisible(false) }

    // MARK: Full screen

    /// The photo goes above the strip, in a container of the screen's size. The strip waits
    /// for the end of the transition, then spans the bottom of the screen.
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreen = true
        strip.setVisible(false)
        guard let current = window.contentView else { return }
        let container = FullScreenContainer(frame: current.frame)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        fullScreenContainer = container
        setContent(current)
        // The photo's shape no longer constrains the window.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        if let screen = window.screen?.frame {
            container.bottomInset = comparison == nil && stripVisible && session.list.count > 1 ? strip.fullScreenHeight(on: screen) : 0
        }
        window.makeFirstResponder(current)
        setWindowButtonsVisible(true)
    }

    /// A screen changed under a full screen window (resolution, another display): the strip
    /// and the photo's room follow it.
    private func refreshFullScreenScreen() {
        guard fullScreen, strip.fullScreenFrame != nil, let screen = window.screen?.frame else { return }
        strip.setFullScreen(screen)
        updateFullScreenRoom()
    }

    func windowDidChangeScreen(_ notification: Notification) { refreshFullScreenScreen() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        strip.setFullScreen(window.screen?.frame ?? window.frame)
        updateStrip()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        strip.setVisible(false)
        strip.setFullScreen(nil)
    }

    /// Back in its own window, which the system gave back: the photo's shape again, and the
    /// strip at its own place.
    func windowDidExitFullScreen(_ notification: Notification) {
        let content = fullScreenContainer?.content
        fullScreenContainer?.content = nil
        fullScreenContainer = nil
        fullScreen = false
        if let content {
            content.frame = window.contentLayoutRect
            window.contentView = content
            window.makeFirstResponder(content)
        }
        if comparison == nil {
            shapedAspect = nil
            display()
            // Saved from here on, now that the window has its photo's shape again.
            if !welcoming { window.setFrameAutosaveName("Viewer") }
            view.refreshHover()
            setWindowButtonsVisible(view.isHovered)
        } else {
            placeComparisonWindow()
        }
        updateStrip()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    }
    func windowDidMiniaturize(_ notification: Notification) { updateStrip() }
    func windowDidDeminiaturize(_ notification: Notification) { updateStrip() }

    /// A size the user chose stays for the next photos, whatever their orientation.
    func windowDidResize(_ notification: Notification) {
        strip.followViewer()
        guard !applyingShape, comparison == nil, !welcoming, !fullScreen else { return }
        chosenHeight = window.frame.height
        shapeCenter = nil
    }

    func windowDidMove(_ notification: Notification) {
        strip.followViewer()
        guard !applyingShape, comparison == nil, !fullScreen else { return }
        // The photo opens where the small window was taken.
        shapeCenter = welcoming ? CGPoint(x: window.frame.midX, y: window.frame.midY) : nil
    }
}
