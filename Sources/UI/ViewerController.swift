import AppKit

/// Connects the session, the pipeline and the view. Navigation here does a cache lookup and
/// a layer commit, nothing else: all waiting happens in the pipeline.
@MainActor
final class ViewerController: NSObject, NSWindowDelegate {
    let session: LibrarySession
    let pipeline: Pipeline
    let view = ViewerView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
    private let comparisonView = ComparisonView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
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
    private var titlePending = false
    private let metadata = MetadataStore()
    private let thumbnails = ThumbnailStore()

    private var stripVisible = Preferences.stripVisible
    private var stripPending = false
    /// Photos picked by Shift-click, by path, to compare instead of the burst.
    private var stripSelection: Set<String> = []

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
        window.setFrameAutosaveName("Viewer")
        // Only the window with the photo's shape exists: no full-screen mode.
        window.collectionBehavior = .fullScreenNone
        window.minSize = NSSize(width: 200, height: 200)
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = view
        if !window.setFrameUsingName("Viewer") { window.center() }
        chosenHeight = window.frame.height

        view.onCommand = { [weak self] in self?.handle($0) }
        comparisonView.onCommand = { [weak self] in self?.handle($0) }
        comparisonView.row.onClick = { [weak self] photo, _ in self?.comparisonRowClicked(photo) }
        strip.preferredScreen = { [weak self] in self?.window.screen }
        strip.view.onClick = { [weak self] photo, extending in self?.stripClicked(photo, extending: extending) }
        strip.view.onLabelClick = { [weak self] in self?.perform(.compare) }
        strip.view.onHoverChanged = { [weak self] in self?.view.refreshHover() }
        thumbnails.onLoaded = { [weak self] _ in self?.scheduleStripUpdate() }
        session.onEvent = { [weak self] in self?.handle($0) }
        pipeline.onFrame = { [weak self] in self?.frameArrived($0) }
        pipeline.onFailed = { [weak self] in self?.frameFailed($0) }
        pipeline.onStale = { [weak self] _ in self?.session.requestScan() }
        pipeline.onNeedsReplan = { [weak self] in self?.replan() }
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
        view.showMessage("⌘O pour ouvrir un dossier ou une photo")
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func open(_ urls: [URL]) {
        leaveComparison()
        showWindow()
        visiblePhoto = nil
        stripSelection = []
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
        case .zoomChanged:
            display()
            replan()
        case .selectSlot(let slot): selectSlot(slot)
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
        case .first: jump(to: 0, direction: 1)
        case .last: jump(to: session.list.count - 1, direction: -1)
        case .delete: deleteCurrent()
        case .undo: undo()
        case .toggleZoom: toggleZoom()
        case .toggleInfo: setInfoVisible(!infoVisible)
        case .revealInFinder: revealInFinder()
        case .exit:
            if !stripSelection.isEmpty {
                stripSelection = []
                scheduleStripUpdate()
            }
            view.exitZoom()
        case .toggleStrip: setStripVisible(!stripVisible)
        case .compare: enterComparison()
        case .keepSelected: break
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

    private func setWindowButtonsVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !visible
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
        guard let screen = window.screen ?? NSScreen.main else { return }
        shapedAspect = aspect
        let center = shapeCenter ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        shapeCenter = center
        let frame = WindowShape.frame(aspect: aspect, height: chosenHeight, center: center, visible: screen.visibleFrame)
        // Also after a launch, when the restored frame may already have this size.
        window.contentAspectRatio = frame.size
        guard frame.size != window.frame.size else { return }
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
        scheduleStripUpdate()
        guard let current = session.list.current else {
            visiblePhoto = nil
            shownTier = nil
            view.showMessage(session.tombstones.isEmpty ? "Aucune photo" : "Aucune photo restante")
            updateInfo()
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
        updateInfo()
        onDisplayed?(current, shownTier)
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
        var seen = Set<Int>()
        metadata.request(offsets.compactMap { offset -> PhotoKey? in
            let at = index + offset
            return photos.indices.contains(at) && seen.insert(at).inserted ? photos[at] : nil
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

    private func updateStrip() {
        guard comparison == nil else {
            strip.setVisible(false)
            updateComparisonRow()
            return
        }
        guard stripVisible, !view.isZoomed, window.isVisible, !window.isMiniaturized,
              session.list.count > 1, let index = session.list.index
        else {
            strip.setVisible(false)
            return
        }
        strip.setVisible(true)
        let photos = session.list.photos
        let half = strip.cellCount / 2
        let cells = (-half...half).map { offset -> StripCell? in
            let at = index + offset
            guard photos.indices.contains(at) else { return nil }
            let photo = photos[at]
            let selected = stripSelection.contains(photo.path)
            return StripCell(
                photo: photo,
                image: thumbnails.image(for: photo),
                mark: offset == 0 ? .current : (selected ? .selected : .none),
                opacity: offset == 0 || selected ? 1 : 0.6
            )
        }
        // Thumbnails beyond the edges too, so that moving along finds them ready.
        let ahead = (1...(half + Self.thumbnailMargin)).flatMap { [index + $0 * direction, index - $0 * direction] }
        thumbnails.request(([index] + ahead).compactMap { photos.indices.contains($0) ? photos[$0] : nil })

        let reach = max(index - Self.burstReach, 0)...min(index + Self.burstReach, photos.count - 1)
        let bursts = PhotoGroups.bursts(dates: photos[reach].map { metadata.metadata(for: $0)?.date })
            .map { ($0.lowerBound + reach.lowerBound)...($0.upperBound + reach.lowerBound) }
        // Positions in the strip, cut to what it shows.
        let brackets = bursts.compactMap { burst -> ClosedRange<Int>? in
            let from = max(burst.lowerBound, index - half), to = min(burst.upperBound, index + half)
            return from <= to ? (from - index + half)...(to - index + half) : nil
        }
        let compareKey = view.shortcuts.keys(for: .compare).first?.label
        let picked = selectedPhotos().count
        var label: String?
        var labelRange: ClosedRange<Int>?
        if picked >= 2 {
            label = "\(picked) sélectionnées"
        } else if let burst = bursts.first(where: { $0.contains(index) }) {
            label = "Rafale de \(burst.count)"
            let from = max(burst.lowerBound, index - half), to = min(burst.upperBound, index + half)
            labelRange = (from - index + half)...(to - index + half)
        }
        if let text = label, let compareKey { label = "\(text)  ·  \(compareKey) pour comparer" }
        strip.view.update(cells: cells, brackets: brackets, label: label, labelRange: labelRange)
    }

    private static let thumbnailMargin = 8

    private func selectedPhotos() -> [PhotoKey] {
        guard !stripSelection.isEmpty else { return [] }
        return session.list.photos.filter { stripSelection.contains($0.path) }
    }

    private func stripClicked(_ photo: PhotoKey, extending: Bool) {
        if extending {
            if !stripSelection.insert(photo.path).inserted { stripSelection.remove(photo.path) }
            updateStrip()
            return
        }
        guard let at = session.list.photos.firstIndex(of: photo), let index = session.list.index, at != index else { return }
        jump(to: at, direction: at < index ? -1 : 1)
    }

    // MARK: Comparison

    /// The Shift-clicked photos, or else the burst around the current photo, or else the
    /// current photo and the next.
    private func photosToCompare() -> [PhotoKey] {
        let picked = selectedPhotos()
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

    private func enterComparison() {
        guard let model = ComparisonModel(photos: photosToCompare(), focusing: session.list.current) else {
            NSSound.beep()
            return
        }
        view.exitZoom()
        preComparisonFrame = window.frame
        preComparisonCenter = shapeCenter ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        // The large window must not come back as the viewer's at the next launch.
        window.setFrameAutosaveName("")
        comparison = model
        stripSelection = []
        strip.setVisible(false)
        comparedVisible = []
        comparisonView.reset()
        comparisonView.frame = window.contentLayoutRect
        window.contentView = comparisonView
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
        guard let screen = window.screen ?? NSScreen.main else { return }
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
        window.contentView = view
        if let preComparisonFrame { window.setFrame(preComparisonFrame, display: true) }
        window.contentAspectRatio = preComparisonFrame?.size ?? window.frame.size
        applyingShape = false
        window.setFrameAutosaveName("Viewer")
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
        for (slot, entry) in model.slots.enumerated() {
            guard let photo = entry else { continue }
            let known = metadata.metadata(for: photo)
            comparisonView.setCaption(slot: slot, number: slot + 1, name: photo.name, settings: known?.settingsText ?? "")
            if let frame = pipeline.cache.best(photo, zoomed: zoomed != nil) {
                comparisonView.showFrame(frame, slot: slot)
                comparedVisible.insert(slot)
                if frame.key.tier == .preview {
                    comparisonView.setBadge("Aperçu", slot: slot)
                } else if let zoomed {
                    comparisonView.setBadge(frame.key.tier == .full ? "\(Int((zoomed * 100).rounded())) %" : "Rendu 100 %…", slot: slot)
                } else {
                    comparisonView.setBadge(nil, slot: slot)
                }
            } else if pipeline.hasFailed(FrameKey(photo: photo, tier: .screen)) {
                comparisonView.showMessage("Impossible de décoder \(photo.name)", slot: slot)
                comparisonView.setBadge(nil, slot: slot)
                comparedVisible.insert(slot)
            } else {
                comparisonView.showMessage(photo.name, slot: slot)
                comparisonView.setBadge(nil, slot: slot)
            }
        }
        metadata.request(model.shown + model.waiting.prefix(ComparisonModel.slotCount))
        scheduleStripUpdate()
    }

    /// Every photo of the comparison: its slot number shows through the marks and the opacity.
    private func updateComparisonRow() {
        guard let model = comparison else { return }
        // A long burst scrolls to keep the focused photo in view.
        let capacity = comparisonView.rowCapacity
        var members = model.members
        if members.count > capacity, let focused = model.focused, let at = members.firstIndex(of: focused) {
            let start = min(max(at - capacity / 2, 0), members.count - capacity)
            members = Array(members[start..<(start + capacity)])
        }
        thumbnails.request(members)
        let cells = members.map { photo -> StripCell? in
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
        comparisonView.row.update(cells: cells, label: nil)
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
        case .first:
            selectSlot(comparison?.slots.firstIndex { $0 != nil } ?? 0)
        case .last:
            selectSlot(comparison?.slots.lastIndex { $0 != nil } ?? 0)
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
        case .toggleInfo, .toggleStrip:
            break
        }
    }

    /// Whatever is deleted must be what the user is looking at.
    private func trashFocusedInComparison() {
        guard let model = comparison, let focused = model.focused, comparedVisible.contains(model.focus) else {
            NSSound.beep()
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
        let count = others.count
        trashInComparison(others, message: "\(count) photo\(count > 1 ? "s" : "") à la corbeille")
    }

    private func trashInComparison(_ photos: [PhotoKey], message: String) {
        // The model first: the list event that follows must find them already gone from it.
        comparison?.remove(photos)
        guard session.trash(photos) else {
            NSSound.beep()
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
        case .restored(let photo):
            navigationToken += 1
            if comparison != nil {
                comparison?.restore(photo)
                focusChanged()
                return
            }
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

    func windowDidMiniaturize(_ notification: Notification) { updateStrip() }
    func windowDidDeminiaturize(_ notification: Notification) { updateStrip() }

    /// A size the user chose stays for the next photos, whatever their orientation.
    func windowDidResize(_ notification: Notification) {
        guard !applyingShape, comparison == nil else { return }
        chosenHeight = window.frame.height
        shapeCenter = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingShape, comparison == nil else { return }
        shapeCenter = nil
    }
}
