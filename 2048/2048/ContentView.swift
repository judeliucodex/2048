import SwiftUI
import Combine
import UIKit

// MARK: - Models

enum AppTheme: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum TileType: String, Codable, Equatable {
    case number
    case bomb       // Explodes 3x3
    case joker      // Wildcard
    case surge      // Clears Row & Column
    case shuffle    // Randomizes board positions
    case glass      // Fragile/Eraser (Tap to remove self)
}

struct Tile: Identifiable, Equatable, Codable {
    let id: UUID
    let value: Int
    let type: TileType
    
    init(value: Int, type: TileType = .number, id: UUID = UUID()) {
        self.value = value
        self.type = type
        self.id = id
    }
}

enum Direction: String, Codable {
    case up, down, left, right
}

struct GameSnapshot: Codable {
    let board: [Tile?]
    let score: Int
    let moveDescription: String
}

struct GameResult: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let score: Int
    let moves: Int
    let duration: TimeInterval
    let gridSize: Int
}

struct GameStats: Codable {
    var totalGamesPlayed: Int = 0
    var totalMovesMade: Int = 0
    var highestScore3x3: Int = 0
    var highestScore4x4: Int = 0
    var highestScore5x5: Int = 0
    var highestScore6x6: Int = 0
    var highestScore7x7: Int = 0
    var highestScore8x8: Int = 0
    var totalScoreAccumulated: Int = 0
    var gameHistory: [GameResult] = []
}

struct PowerupConfig: Codable {
    var isEnabled: Bool = true
    var weight: Double = 5.0 // 1.0 to 10.0
}

struct AppSettings: Codable {
    // Visuals
    var appTheme: AppTheme = .system
    var themeColorName: String = "Orange"
    
    // Gameplay
    var allowUndoRedo: Bool = true // False = Hardcore Mode
    var dragSensitivity: Double = 20.0
    
    // Powerups Master Control
    var masterPowerupToggle: Bool = true
    var powerupFrequency: Double = 0.05 // 5% default, max 40%
    
    // Individual Powerup Configs
    var configBomb: PowerupConfig = PowerupConfig(isEnabled: true, weight: 5)
    var configJoker: PowerupConfig = PowerupConfig(isEnabled: true, weight: 3)
    var configSurge: PowerupConfig = PowerupConfig(isEnabled: true, weight: 3)
    var configShuffle: PowerupConfig = PowerupConfig(isEnabled: true, weight: 2)
    var configGlass: PowerupConfig = PowerupConfig(isEnabled: true, weight: 6)
    
    // Interface
    var hapticsEnabled: Bool = true
    var showTimer: Bool = true
}

struct SavedGameState: Codable {
    let stats: GameStats
    let settings: AppSettings
}

// MARK: - ViewModel

class GameViewModel: ObservableObject {
    @Published var board: [Tile?] = []
    @Published var score: Int = 0
    @Published var gridSize: Int = 4 {
        didSet {
            if oldValue != gridSize && !isLoading {
                finishCurrentGame(reason: "Grid Change")
                resetGame()
            }
        }
    }
    @Published var gameOver: Bool = false
    @Published var isPaused: Bool = false
    @Published var showCelebration: Bool = false
    
    // Time & History
    @Published var timeElapsed: TimeInterval = 0
    @Published var isTimerRunning: Bool = false
    @Published var undoStack: [GameSnapshot] = []
    @Published var redoStack: [GameSnapshot] = []
    @Published var movesInCurrentGame: Int = 0
    
    // Settings & Stats
    @Published var stats: GameStats = GameStats()
    @Published var settings: AppSettings = AppSettings() {
        didSet { saveData() }
    }
    
    private var sessionHighScoreBroken = false
    
    var themeColor: Color {
        switch settings.themeColorName {
        case "Blue": return .blue
        case "Purple": return .purple
        case "Pink": return .pink
        case "Green": return .green
        default: return .orange
        }
    }
    
    var nextGoal: Int {
        let maxTile = board.compactMap { $0?.value }.max() ?? 0
        return maxTile == 0 ? 2048 : (maxTile < 2048 ? maxTile * 2 : maxTile * 2)
    }
    
    private var isLoading = false
    private let saveKey = "2048_Glass_v9_Final"
    private var timerCancellable: AnyCancellable?
    
    init() {
        loadData()
        resetGame()
    }
    
    deinit { timerCancellable?.cancel() }
    
    // MARK: - Timer
    
    func startTimer() {
        stopTimer()
        guard !gameOver, !isPaused else { return }
        
        isTimerRunning = true
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isTimerRunning, !self.isPaused, !self.gameOver else { return }
                self.timeElapsed += 1
            }
    }
    
    func stopTimer() {
        isTimerRunning = false
        timerCancellable?.cancel()
    }
    
    func pauseGame() {
        guard !gameOver else { return }
        isPaused = true
        stopTimer()
        triggerHaptic(style: .medium)
    }
    
    func resumeGame() {
        guard !gameOver else { return }
        isPaused = false
        startTimer()
        triggerHaptic(style: .medium)
    }
    
    // MARK: - Game Control
    
    func resetGame() {
        isLoading = true
        board = Array(repeating: nil, count: gridSize * gridSize)
        score = 0
        movesInCurrentGame = 0
        timeElapsed = 0
        undoStack.removeAll()
        redoStack.removeAll()
        gameOver = false
        isPaused = false
        showCelebration = false
        sessionHighScoreBroken = false
        
        spawnTile()
        spawnTile()
        isLoading = false
        
        startTimer()
    }
    
    func finishCurrentGame(reason: String) {
        if score > 0 || movesInCurrentGame > 0 {
            let result = GameResult(
                date: Date(),
                score: score,
                moves: movesInCurrentGame,
                duration: timeElapsed,
                gridSize: gridSize
            )
            stats.gameHistory.insert(result, at: 0)
            stats.totalGamesPlayed += 1
            stats.totalScoreAccumulated += score
            saveData()
        }
    }
    
    func spawnTile() {
        let emptyIndices = board.indices.filter { board[$0] == nil }
        guard let index = emptyIndices.randomElement() else { return }
        
        let isHardcore = !settings.allowUndoRedo
        
        // Powerup Logic
        if !isHardcore && settings.masterPowerupToggle {
            let roll = Double.random(in: 0...1)
            if roll < settings.powerupFrequency {
                // Determine which powerup
                let types: [(TileType, Double)] = [
                    (.bomb, settings.configBomb.isEnabled ? settings.configBomb.weight : 0),
                    (.joker, settings.configJoker.isEnabled ? settings.configJoker.weight : 0),
                    (.surge, settings.configSurge.isEnabled ? settings.configSurge.weight : 0),
                    (.shuffle, settings.configShuffle.isEnabled ? settings.configShuffle.weight : 0),
                    (.glass, settings.configGlass.isEnabled ? settings.configGlass.weight : 0)
                ]
                
                let totalWeight = types.reduce(0) { $0 + $1.1 }
                
                if totalWeight > 0 {
                    var rnd = Double.random(in: 0..<totalWeight)
                    for (type, weight) in types {
                        if rnd < weight {
                            board[index] = Tile(value: 0, type: type)
                            return
                        }
                        rnd -= weight
                    }
                }
            }
        }
        
        // Default Spawn (Number)
        let value = Double.random(in: 0...1) < 0.9 ? 2 : 4
        board[index] = Tile(value: value, type: .number)
    }
    
    // MARK: - Powerup Logic
    
    func handleTileTap(at index: Int) {
        guard !isPaused, !gameOver else { return }
        guard let tile = board[index] else { return }
        
        switch tile.type {
        case .bomb: activateBomb(at: index)
        case .surge: activateSurge(at: index)
        case .shuffle: activateShuffle(at: index)
        case .glass: activateGlass(at: index)
        default: break
        }
    }
    
    func activateBomb(at index: Int) {
        saveSnapshot(desc: "Bomb Used")
        let row = index / gridSize
        let col = index % gridSize
        triggerHaptic(style: .heavy)
        withAnimation(.easeOut(duration: 0.2)) {
            for r in (row - 1)...(row + 1) {
                for c in (col - 1)...(col + 1) {
                    if r >= 0 && r < gridSize && c >= 0 && c < gridSize {
                        board[r * gridSize + c] = nil
                    }
                }
            }
        }
    }
    
    func activateSurge(at index: Int) {
        saveSnapshot(desc: "Surge Used")
        let row = index / gridSize
        let col = index % gridSize
        triggerHaptic(style: .heavy)
        withAnimation(.easeOut(duration: 0.2)) {
            for c in 0..<gridSize { board[row * gridSize + c] = nil }
            for r in 0..<gridSize { board[r * gridSize + col] = nil }
        }
    }
    
    func activateGlass(at index: Int) {
        saveSnapshot(desc: "Glass Removed")
        triggerHaptic(style: .light)
        withAnimation {
            board[index] = nil
        }
    }
    
    func activateShuffle(at index: Int) {
        saveSnapshot(desc: "Shuffle Used")
        triggerHaptic(style: .medium)
        
        // Collect all non-empty tiles EXCEPT the shuffle tile itself (it gets used up)
        var tilesToShuffle: [Tile] = []
        for i in 0..<board.count {
            if i != index, let t = board[i] {
                tilesToShuffle.append(t)
            }
        }
        
        // Shuffle the list
        tilesToShuffle.shuffle()
        
        withAnimation(.easeInOut(duration: 0.4)) {
            // Clear board
            board = Array(repeating: nil, count: gridSize * gridSize)
            
            // Repopulate randomly
            let shuffledIndices = (0..<board.count).shuffled()
            for (i, tile) in tilesToShuffle.enumerated() {
                if i < shuffledIndices.count {
                    board[shuffledIndices[i]] = tile
                }
            }
        }
    }
    
    func move(_ direction: Direction) {
        guard !gameOver, !isPaused else { return }
        
        let currentSnapshot = GameSnapshot(board: board, score: score, moveDescription: "Move \(direction)")
        var newScore = score
        let currentBoard = board
        
        func processLine(_ line: [Tile?]) -> [Tile?] {
            let compact = line.compactMap { $0 }
            var result: [Tile?] = []
            var skip = false
            
            for i in 0..<compact.count {
                if skip { skip = false; continue }
                
                if i + 1 < compact.count {
                    let current = compact[i]
                    let next = compact[i+1]
                    
                    // Obstacles: Bomb, Surge, Shuffle, Glass act as walls
                    if current.type != .number && current.type != .joker { result.append(current); continue }
                    if next.type != .number && next.type != .joker { result.append(current); continue }
                    
                    // Logic
                    var merged = false
                    var mergedValue = 0
                    
                    if current.type == .joker || next.type == .joker {
                        let baseVal = max(current.value, next.value)
                        mergedValue = (baseVal == 0 ? 2 : baseVal) * 2
                        merged = true
                    } else if current.value == next.value {
                        mergedValue = current.value * 2
                        merged = true
                    }
                    
                    if merged {
                        newScore += mergedValue
                        result.append(Tile(value: mergedValue, type: .number))
                        skip = true
                    } else {
                        result.append(current)
                    }
                } else {
                    result.append(compact[i])
                }
            }
            while result.count < gridSize { result.append(nil) }
            return result
        }
        
        var lines: [[Tile?]] = []
        switch direction {
        case .left:
            for r in 0..<gridSize { lines.append(processLine((0..<gridSize).map { currentBoard[r * gridSize + $0] })) }
        case .right:
            for r in 0..<gridSize { lines.append(processLine((0..<gridSize).map { currentBoard[r * gridSize + $0] }.reversed()).reversed()) }
        case .up:
            for c in 0..<gridSize { lines.append(processLine((0..<gridSize).map { currentBoard[$0 * gridSize + c] })) }
        case .down:
            for c in 0..<gridSize { lines.append(processLine((0..<gridSize).map { currentBoard[$0 * gridSize + c] }.reversed()).reversed()) }
        }
        
        var tempBoard = Array(repeating: nil as Tile?, count: gridSize * gridSize)
        if direction == .left || direction == .right {
            for r in 0..<gridSize { for c in 0..<gridSize { tempBoard[r * gridSize + c] = lines[r][c] } }
        } else {
            for c in 0..<gridSize { for r in 0..<gridSize { tempBoard[r * gridSize + c] = lines[c][r] } }
        }
        
        if tempBoard != board {
            if settings.allowUndoRedo {
                undoStack.append(currentSnapshot)
                redoStack.removeAll()
            }
            movesInCurrentGame += 1
            stats.totalMovesMade += 1
            
            triggerHaptic(style: .light)
            
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                board = tempBoard
                score = newScore
            }
            spawnTile()
            updateHighScores(currentScore: newScore)
            checkGameOver()
            saveData()
        }
    }
    
    func saveSnapshot(desc: String) {
        if settings.allowUndoRedo {
            let snap = GameSnapshot(board: board, score: score, moveDescription: desc)
            undoStack.append(snap)
            redoStack.removeAll()
        }
    }
    
    func undo() {
        guard settings.allowUndoRedo, !isPaused, let prev = undoStack.popLast() else { return }
        let currentSnapshot = GameSnapshot(board: board, score: score, moveDescription: "Undo")
        redoStack.append(currentSnapshot)
        triggerHaptic(style: .medium)
        withAnimation {
            board = prev.board
            score = prev.score
            if movesInCurrentGame > 0 { movesInCurrentGame -= 1 }
        }
    }
    
    func redo() {
        guard settings.allowUndoRedo, !isPaused, let next = redoStack.popLast() else { return }
        let currentSnapshot = GameSnapshot(board: board, score: score, moveDescription: "Redo")
        undoStack.append(currentSnapshot)
        triggerHaptic(style: .medium)
        withAnimation {
            board = next.board
            score = next.score
            movesInCurrentGame += 1
        }
    }
    
    func checkGameOver() {
        if board.contains(where: { $0 == nil }) { return }
        // Powerups (except Glass/Eraser/Shuffle) generally save you, so if they exist, not game over
        if board.contains(where: { $0?.type != .number }) { return }
        
        for r in 0..<gridSize {
            for c in 0..<gridSize {
                let idx = r * gridSize + c
                guard let tile = board[idx] else { continue }
                if c + 1 < gridSize, let neighbor = board[r * gridSize + (c + 1)], neighbor.value == tile.value { return }
                if r + 1 < gridSize, let neighbor = board[(r + 1) * gridSize + c], neighbor.value == tile.value { return }
            }
        }
        
        stopTimer()
        finishCurrentGame(reason: "Lost")
        triggerHaptic(style: .heavy)
        saveData()
        
        withAnimation(.easeIn(duration: 0.6)) { // FASTER
            gameOver = true
        }
    }
    
    func updateHighScores(currentScore: Int) {
        var oldBest = 0
        switch gridSize {
        case 3: oldBest = stats.highestScore3x3; if currentScore > oldBest { stats.highestScore3x3 = currentScore }
        case 4: oldBest = stats.highestScore4x4; if currentScore > oldBest { stats.highestScore4x4 = currentScore }
        case 5: oldBest = stats.highestScore5x5; if currentScore > oldBest { stats.highestScore5x5 = currentScore }
        case 6: oldBest = stats.highestScore6x6; if currentScore > oldBest { stats.highestScore6x6 = currentScore }
        case 7: oldBest = stats.highestScore7x7; if currentScore > oldBest { stats.highestScore7x7 = currentScore }
        case 8: oldBest = stats.highestScore8x8; if currentScore > oldBest { stats.highestScore8x8 = currentScore }
        default: break
        }
        
        if currentScore > oldBest && oldBest > 0 && !sessionHighScoreBroken {
            sessionHighScoreBroken = true
            showCelebration = true
            triggerHaptic(style: .heavy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { // FASTER RESET
                withAnimation { self.showCelebration = false }
            }
        }
    }
    
    func resetHighScores() {
        stats.highestScore3x3 = 0
        stats.highestScore4x4 = 0
        stats.highestScore5x5 = 0
        stats.highestScore6x6 = 0
        stats.highestScore7x7 = 0
        stats.highestScore8x8 = 0
        saveData()
    }
    
    func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    // MARK: - Persistence
    
    func saveData() {
        let state = SavedGameState(stats: stats, settings: settings)
        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }
    
    func loadData() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        do {
            let state = try JSONDecoder().decode(SavedGameState.self, from: data)
            self.stats = state.stats
            self.settings = state.settings
        } catch {
            print("Failed to load: \(error)")
        }
    }
    
    func currentBestScore() -> Int {
        switch gridSize {
        case 3: return stats.highestScore3x3
        case 4: return stats.highestScore4x4
        case 5: return stats.highestScore5x5
        case 6: return stats.highestScore6x6
        case 7: return stats.highestScore7x7
        case 8: return stats.highestScore8x8
        default: return 0
        }
    }
    
    func getFormattedTime() -> String {
        return GameViewModel.formatDuration(timeElapsed)
    }
    
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Views

struct BackgroundView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var animateGradient = false
    
    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(colors: [Color(red: 0.95, green: 0.90, blue: 0.85), Color(red: 1.0, green: 0.95, blue: 0.90)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            
            GeometryReader { proxy in
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: animateGradient ? -50 : 50, y: animateGradient ? -50 : 50)
                    .animation(.easeInOut(duration: 10).repeatForever(autoreverses: true), value: animateGradient)
                
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 250, height: 250)
                    .blur(radius: 60)
                    .offset(x: proxy.size.width - 200, y: proxy.size.height - 300)
                    .offset(x: animateGradient ? 30 : -30, y: animateGradient ? 50 : -50)
                    .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: animateGradient)
            }
        }
        .ignoresSafeArea()
        .onAppear { animateGradient = true }
    }
}

struct ConfettiView: View {
    @State private var animate = false
    let colors: [Color] = [.red, .blue, .green, .yellow, .pink, .orange, .purple]
    
    var body: some View {
        ZStack {
            ForEach(0..<50) { _ in
                Circle()
                    .fill(colors.randomElement()!)
                    .frame(width: CGFloat.random(in: 5...10))
                    .offset(x: animate ? CGFloat.random(in: -200...200) : 0,
                            y: animate ? CGFloat.random(in: -200...400) : 0)
                    .opacity(animate ? 0 : 1)
            }
            
            Text("NEW HIGH SCORE!")
                .font(.title2.bold())
                .foregroundColor(.white)
                .padding()
                .background(Color.orange)
                .cornerRadius(10)
                .shadow(radius: 10)
                .scaleEffect(animate ? 1.1 : 0.5)
                .opacity(animate ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { // FASTER
                animate = true
            }
        }
    }
}

struct TileView: View {
    let tile: Tile?
    let size: CGFloat
    let themeColor: Color
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 3)
            
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
            
            if let t = tile {
                content(for: t)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(tile != nil ? 1.0 : 0.9)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: tile)
    }
    
    @ViewBuilder
    func content(for t: Tile) -> some View {
        switch t.type {
        case .number:
            Text("\(t.value)")
                .font(.system(size: fontSize(for: t.value), weight: .bold, design: .rounded))
                .foregroundColor(textColor(for: t.value))
        case .bomb: Text("💣").font(.system(size: size * 0.5))
        case .joker: Text("🃏").font(.system(size: size * 0.5))
        case .surge: Text("⚡️").font(.system(size: size * 0.5))
        case .shuffle: Text("🔀").font(.system(size: size * 0.5))
        case .glass: Text("🪄").font(.system(size: size * 0.5))
        }
    }
    
    private var backgroundColor: Color {
        guard let t = tile else {
            return colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
        }
        
        switch t.type {
        case .bomb: return .black.opacity(0.7)
        case .joker: return .purple.opacity(0.7)
        case .surge: return .yellow.opacity(0.8)
        case .shuffle: return .blue.opacity(0.8)
        case .glass: return .gray.opacity(0.6)
        case .number:
            switch t.value {
            case 2: return themeColor.opacity(0.4)
            case 4: return themeColor.opacity(0.5)
            case 8: return themeColor.opacity(0.6)
            case 16: return themeColor.opacity(0.7)
            case 32: return themeColor.opacity(0.8)
            case 64: return themeColor.opacity(0.9)
            default: return themeColor
            }
        }
    }
    
    private func textColor(for value: Int) -> Color {
        return value <= 4 ? (colorScheme == .dark ? .white : Color(white: 0.3)) : .white
    }
    
    private func fontSize(for value: Int) -> CGFloat {
        let baseSize: CGFloat = size > 40 ? 30 : 16
        switch "\(value)".count {
        case 1, 2: return baseSize
        case 3: return baseSize * 0.8
        case 4: return baseSize * 0.65
        default: return baseSize * 0.5
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()
    
    var body: some View {
        TabView {
            GameView(viewModel: viewModel)
                .tabItem { Label("Play", systemImage: "gamecontroller.fill") }
            
            AnalyticsView(viewModel: viewModel)
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .accentColor(viewModel.themeColor)
        .preferredColorScheme(
            viewModel.settings.appTheme == .system ? nil :
                (viewModel.settings.appTheme == .dark ? .dark : .light)
        )
    }
}

// MARK: - Game View

struct GameView: View {
    @ObservedObject var viewModel: GameViewModel
    @Environment(\.colorScheme) var colorScheme
    
    var spacing: CGFloat { viewModel.gridSize > 6 ? 6 : 10 }
    
    var body: some View {
        ZStack {
            BackgroundView()
            
            // MAIN GAME LAYER
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        headerView
                        
                        // Controls (Top)
                        HStack {
                            Menu {
                                ForEach(3...8, id: \.self) { i in
                                    Button("\(i)x\(i) Grid") { viewModel.gridSize = i }
                                }
                            } label: {
                                Label("\(viewModel.gridSize)x\(viewModel.gridSize)", systemImage: "square.grid.2x2")
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                viewModel.finishCurrentGame(reason: "User Reset")
                                withAnimation { viewModel.resetGame() }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("New Game")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(viewModel.themeColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                .shadow(radius: 5)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Game Board Area
                        ZStack {
                            boardView(geometry: geometry)
                                .padding(12)
                                .background(.regularMaterial)
                                .cornerRadius(20)
                                .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 10)
                                .gesture(
                                    DragGesture(minimumDistance: viewModel.settings.dragSensitivity, coordinateSpace: .local)
                                        .onEnded { value in
                                            let horizontal = value.translation.width
                                            let vertical = value.translation.height
                                            if abs(horizontal) > abs(vertical) {
                                                viewModel.move(horizontal > 0 ? .right : .left)
                                            } else {
                                                viewModel.move(vertical > 0 ? .down : .up)
                                            }
                                        }
                                )
                            
                            if viewModel.showCelebration {
                                ConfettiView().zIndex(20)
                            }
                        }
                        .frame(maxWidth: min(geometry.size.width - 30, 500))
                        
                        // Footer Controls
                        footerControls
                    }
                    Spacer()
                }
                .frame(width: geometry.size.width)
            }
            
            // OVERLAYS
            
            // Game Over
            if viewModel.gameOver {
                Color.black.opacity(0.3).ignoresSafeArea().zIndex(9)
                gameOverOverlay.zIndex(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            
            // Pause - Custom Full Screen or Overlay
            if viewModel.isPaused && !viewModel.gameOver {
                Color.black.opacity(0.3).ignoresSafeArea().zIndex(9)
                pauseOverlay.zIndex(10)
                    .transition(.opacity)
            }
        }
    }
    
    var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("2048")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundColor(colorScheme == .dark ? .white : Color(white: 0.2))
                
                if viewModel.settings.showTimer {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                        Text(viewModel.getFormattedTime())
                    }
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                if viewModel.settings.allowUndoRedo {
                    VStack {
                        Text("NEXT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Text("\(viewModel.nextGoal)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(viewModel.themeColor)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(width: 55, height: 55)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                glassScoreBox(title: "SCORE", value: viewModel.score)
                glassScoreBox(title: "BEST", value: viewModel.currentBestScore())
            }
        }
        .frame(maxWidth: 500)
        .padding(.horizontal)
    }
    
    func glassScoreBox(title: String, value: Int) -> some View {
        VStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(width: 70, height: 55)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
    
    func boardView(geometry: GeometryProxy) -> some View {
        let maxWidth = min(geometry.size.width - 54, 460)
        let tileSize = (maxWidth - (CGFloat(viewModel.gridSize - 1) * spacing)) / CGFloat(viewModel.gridSize)
        let columns = Array(repeating: GridItem(.fixed(tileSize), spacing: spacing), count: viewModel.gridSize)
        
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(0..<(viewModel.gridSize * viewModel.gridSize), id: \.self) { index in
                if index < viewModel.board.count {
                    TileView(tile: viewModel.board[index], size: tileSize, themeColor: viewModel.themeColor)
                        .onTapGesture {
                            viewModel.handleTileTap(at: index)
                        }
                }
            }
        }
    }
    
    // MARK: - Overlays
    
    var gameOverOverlay: some View {
        VStack(spacing: 25) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 50))
                .foregroundColor(viewModel.themeColor)
                .shadow(radius: 5)
            
            Text("Game Over")
                .font(.largeTitle.bold())
                .foregroundColor(.primary)
            
            VStack(spacing: 10) {
                HStack {
                    Text("Score:").foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.score)").bold()
                }
                HStack {
                    Text("Moves:").foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.movesInCurrentGame)").bold()
                }
            }
            .frame(maxWidth: 200)
            .font(.headline)
            
            Button("Try Again") {
                withAnimation { viewModel.resetGame() }
            }
            .padding()
            .padding(.horizontal)
            .background(viewModel.themeColor)
            .foregroundColor(.white)
            .cornerRadius(12)
            .shadow(radius: 3)
        }
        .padding(30)
        .background(.regularMaterial)
        .cornerRadius(20)
        .shadow(radius: 20)
    }
    
    var pauseOverlay: some View {
        VStack(spacing: 25) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(viewModel.themeColor)
            
            Text("Game Paused")
                .font(.title.bold())
                .foregroundColor(.primary)
            
            // Resume Button INSIDE popup
            Button(action: {
                viewModel.resumeGame()
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Resume Game")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .padding(.horizontal, 20)
                .background(viewModel.themeColor)
                .cornerRadius(15)
                .shadow(radius: 5)
            }
        }
        .padding(50)
        .background(.regularMaterial)
        .cornerRadius(20)
        .shadow(radius: 20)
    }
    
    var footerControls: some View {
        HStack(spacing: 25) {
            if viewModel.settings.allowUndoRedo {
                glassButton(icon: "arrow.uturn.backward", label: "Undo", action: viewModel.undo, disabled: viewModel.undoStack.isEmpty)
            }
            
            // Only show Pause button if NOT paused
            if !viewModel.isPaused {
                Button(action: { viewModel.pauseGame() }) {
                    VStack(spacing: 5) {
                        Image(systemName: "pause.fill")
                            .font(.title2)
                        Text("Pause").font(.caption2)
                    }
                    .frame(width: 70, height: 70)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .foregroundColor(viewModel.themeColor)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
            } else {
                // Placeholder to keep Undo/Redo positions stable when pause button disappears
                // Or you can remove it. Let's keep a spacer of same size
                Color.clear.frame(width: 70, height: 70)
            }
            
            if viewModel.settings.allowUndoRedo {
                glassButton(icon: "arrow.uturn.forward", label: "Redo", action: viewModel.redo, disabled: viewModel.redoStack.isEmpty)
            }
        }
        .padding(.top, 10)
    }
    
    func glassButton(icon: String, label: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption2)
            }
            .frame(width: 60, height: 60)
            .background(disabled ? .ultraThinMaterial : .regularMaterial)
            .clipShape(Circle())
            .foregroundColor(disabled ? .secondary : viewModel.themeColor)
            .shadow(color: .black.opacity(disabled ? 0 : 0.1), radius: 5, y: 3)
        }
        .disabled(disabled)
    }
}

// MARK: - Analytics View

struct AnalyticsView: View {
    @ObservedObject var viewModel: GameViewModel
    
    var body: some View {
        NavigationView {
            ZStack {
                BackgroundView()
                List {
                    Section(header: Text("Performance")) {
                        statRow(title: "Total Games", value: "\(viewModel.stats.totalGamesPlayed)")
                        statRow(title: "Total Moves", value: "\(viewModel.stats.totalMovesMade)")
                        statRow(title: "Avg Score", value: String(format: "%.0f", averageScore()))
                    }
                    Section(header: Text("High Scores")) {
                        statRow(title: "3x3 Best", value: "\(viewModel.stats.highestScore3x3)")
                        statRow(title: "4x4 Best", value: "\(viewModel.stats.highestScore4x4)")
                        statRow(title: "5x5 Best", value: "\(viewModel.stats.highestScore5x5)")
                        statRow(title: "6x6 Best", value: "\(viewModel.stats.highestScore6x6)")
                        statRow(title: "8x8 Best", value: "\(viewModel.stats.highestScore8x8)")
                    }
                    Section(header: Text("History")) {
                        if viewModel.stats.gameHistory.isEmpty {
                            Text("No history yet").foregroundColor(.secondary)
                        } else {
                            ForEach(viewModel.stats.gameHistory) { game in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("\(game.gridSize)x\(game.gridSize) Game")
                                            .font(.headline)
                                        Text(game.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(game.score) pts")
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.bold)
                                            .foregroundColor(viewModel.themeColor)
                                        Text("\(game.moves) moves • \(GameViewModel.formatDuration(game.duration))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Analytics")
        }
    }
    
    func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).bold().foregroundColor(viewModel.themeColor)
        }
    }
    
    func averageScore() -> Double {
        guard viewModel.stats.totalGamesPlayed > 0 else { return 0 }
        return Double(viewModel.stats.totalScoreAccumulated) / Double(viewModel.stats.totalGamesPlayed)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: GameViewModel
    @State private var showingResetAlert = false
    
    let colors = ["Orange", "Blue", "Purple", "Pink", "Green"]
    
    var body: some View {
        NavigationView {
            ZStack {
                BackgroundView()
                Form {
                    Section(header: Text("Theme")) {
                        Picker("Appearance", selection: $viewModel.settings.appTheme) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.rawValue).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Picker("Accent Color", selection: $viewModel.settings.themeColorName) {
                            ForEach(colors, id: \.self) { color in
                                Text(color).tag(color)
                            }
                        }
                    }
                    
                    Section(header: Text("Mode")) {
                        Toggle("Hardcore Mode", isOn: Binding(
                            get: { !viewModel.settings.allowUndoRedo },
                            set: { viewModel.settings.allowUndoRedo = !$0 }
                        ))
                        .tint(viewModel.themeColor)
                        
                        if !viewModel.settings.allowUndoRedo {
                            Text("Hardcore: Undo disabled. Powerups disabled.")
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                    
                    // Powerups Configuration
                    if viewModel.settings.allowUndoRedo {
                        Section(header: Text("Powerups System")) {
                            Toggle("Enable All Powerups", isOn: $viewModel.settings.masterPowerupToggle)
                                .tint(viewModel.themeColor)
                            
                            if viewModel.settings.masterPowerupToggle {
                                VStack(alignment: .leading) {
                                    Text("Spawn Frequency: \(Int(viewModel.settings.powerupFrequency * 100))%")
                                    Slider(value: $viewModel.settings.powerupFrequency, in: 0.01...0.40, step: 0.01) {
                                        Text("Freq")
                                    } minimumValueLabel: { Text("1%") } maximumValueLabel: { Text("40%") }
                                    .tint(viewModel.themeColor)
                                }
                            }
                        }
                        
                        if viewModel.settings.masterPowerupToggle {
                            Section(header: Text("Powerup Weights"), footer: Text("Higher weight = Appears more often")) {
                                powerupRow(name: "💣 Bomb", config: $viewModel.settings.configBomb)
                                powerupRow(name: "🃏 Joker", config: $viewModel.settings.configJoker)
                                powerupRow(name: "⚡️ Surge", config: $viewModel.settings.configSurge)
                                powerupRow(name: "🔀 Shuffle", config: $viewModel.settings.configShuffle)
                                powerupRow(name: "🪄 Glass", config: $viewModel.settings.configGlass)
                            }
                        }
                    }
                    
                    Section(header: Text("Controls")) {
                        VStack(alignment: .leading) {
                            Text("Swipe Sensitivity")
                            Slider(value: $viewModel.settings.dragSensitivity, in: 10...100, step: 5) {
                                Text("Sensitivity")
                            } minimumValueLabel: { Text("High") } maximumValueLabel: { Text("Low") }
                            .tint(viewModel.themeColor)
                        }
                        Toggle("Haptic Feedback", isOn: $viewModel.settings.hapticsEnabled)
                        Toggle("Show Timer", isOn: $viewModel.settings.showTimer)
                    }
                    
                    Section(header: Text("Data")) {
                        Button("Reset High Scores") { showingResetAlert = true }
                        .foregroundColor(.red)
                        .alert("Reset High Scores?", isPresented: $showingResetAlert) {
                            Button("Cancel", role: .cancel) { }
                            Button("Reset", role: .destructive) { viewModel.resetHighScores() }
                        }
                    }
                    
                    Section(header: Text("Rules")) {
                        DisclosureGroup("Powerup Guide") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("💣 **Bomb**: Explode 3x3 area.")
                                Text("🃏 **Joker**: Wildcard for merging.")
                                Text("⚡️ **Surge**: Clear Row & Column.")
                                Text("🔀 **Shuffle**: Rearrange all tiles.")
                                Text("🪄 **Glass**: Tap to remove itself.")
                            }
                            .font(.caption)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }
    
    func powerupRow(name: String, config: Binding<PowerupConfig>) -> some View {
        VStack {
            Toggle(name, isOn: config.isEnabled)
                .tint(viewModel.themeColor)
            
            if config.wrappedValue.isEnabled {
                HStack {
                    Text("Weight: \(Int(config.wrappedValue.weight))")
                        .font(.caption).foregroundColor(.secondary)
                    Slider(value: config.weight, in: 1...10, step: 1)
                        .tint(viewModel.themeColor)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
