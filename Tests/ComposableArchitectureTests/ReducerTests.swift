import Combine
import CombineSchedulers
import ComposableArchitecture
import XCTest
import os.signpost

final class ReducerTests: XCTestCase {
  var cancellables: Set<AnyCancellable> = []

  func testCallableAsFunction() {
    let reducer = Reducer<Int, Void, Void> { state, _, _ in
      state += 1
      return .none
    }

    var state = 0
    _ = reducer.run(&state, (), ())
    XCTAssertEqual(state, 1)
  }

  func testCombine_EffectsAreMerged() {
    typealias Scheduler = AnySchedulerOf<DispatchQueue>
    enum Action: Equatable {
      case increment
    }

    var fastValue: Int?
    let fastReducer = Reducer<Int, Action, Scheduler> { state, _, scheduler in
      state += 1
      return Effect.fireAndForget { fastValue = 42 }
        .delay(for: 1, scheduler: scheduler)
        .eraseToEffect()
    }

    var slowValue: Int?
    let slowReducer = Reducer<Int, Action, Scheduler> { state, _, scheduler in
      state += 1
      return Effect.fireAndForget { slowValue = 1729 }
        .delay(for: 2, scheduler: scheduler)
        .eraseToEffect()
    }

    let scheduler = DispatchQueue.test
    let store = TestStore(
      initialState: 0,
      reducer: .combine(fastReducer, slowReducer),
      environment: scheduler.eraseToAnyScheduler()
    )

    store.send(.increment) {
      $0 = 2
    }
    // Waiting a second causes the fast effect to fire.
    scheduler.advance(by: 1)
    XCTAssertEqual(fastValue, 42)
    // Waiting one more second causes the slow effect to fire. This proves that the effects
    // are merged together, as opposed to concatenated.
    scheduler.advance(by: 1)
    XCTAssertEqual(slowValue, 1729)
  }

  func testCombine() {
    enum Action: Equatable {
      case increment
    }

    var childEffectExecuted = false
    let childReducer = Reducer<Int, Action, Void> { state, _, _ in
      state += 1
      return Effect.fireAndForget { childEffectExecuted = true }
        .eraseToEffect()
    }

    var mainEffectExecuted = false
    let mainReducer = Reducer<Int, Action, Void> { state, _, _ in
      state += 1
      return Effect.fireAndForget { mainEffectExecuted = true }
        .eraseToEffect()
    }
    .combined(with: childReducer)

    let store = TestStore(
      initialState: 0,
      reducer: mainReducer,
      environment: ()
    )

    store.send(.increment) {
      $0 = 2
    }

    XCTAssertTrue(childEffectExecuted)
    XCTAssertTrue(mainEffectExecuted)
  }

  func testDebug() {
    enum Action: Equatable { case incr, noop }
    struct State: Equatable { var count = 0 }

    var logs: [String] = []
    let logsExpectation = self.expectation(description: "logs")
    logsExpectation.expectedFulfillmentCount = 2

    let reducer = Reducer<State, Action, Void> { state, action, _ in
      switch action {
      case .incr:
        state.count += 1
        return .none
      case .noop:
        return .none
      }
    }
    .debug("[prefix]") { _ in
      DebugEnvironment(
        printer: {
          logs.append($0)
          logsExpectation.fulfill()
        }
      )
    }

    let store = TestStore(
      initialState: State(),
      reducer: reducer,
      environment: ()
    )
    store.send(.incr) { $0.count = 1 }
    store.send(.noop)

    self.wait(for: [logsExpectation], timeout: 2)

    XCTAssertEqual(
      logs,
      [
        #"""
        [prefix]: received action:
          Action.incr
          State(
        −   count: 0
        +   count: 1
          )

        """#,
        #"""
        [prefix]: received action:
          Action.noop
          (No state changes)

        """#,
      ]
    )
  }

  func testDebug_ActionFormat_OnlyLabels() {
    enum Action: Equatable { case incr(Bool) }
    struct State: Equatable { var count = 0 }

    var logs: [String] = []
    let logsExpectation = self.expectation(description: "logs")

    let reducer = Reducer<State, Action, Void> { state, action, _ in
      switch action {
      case let .incr(bool):
        state.count += bool ? 1 : 0
        return .none
      }
    }
    .debug("[prefix]", actionFormat: .labelsOnly) { _ in
      DebugEnvironment(
        printer: {
          logs.append($0)
          logsExpectation.fulfill()
        }
      )
    }

    let viewStore = ViewStore(
      Store(
        initialState: State(),
        reducer: reducer,
        environment: ()
      )
    )
    viewStore.send(.incr(true))

    self.wait(for: [logsExpectation], timeout: 2)

    XCTAssertEqual(
      logs,
      [
        #"""
        [prefix]: received action:
          Action.incr
          State(
        −   count: 0
        +   count: 1
          )

        """#
      ]
    )
  }

  func testDefaultSignpost() {
    let reducer = Reducer<Int, Void, Void>.empty.signpost(log: .default)
    var n = 0
    let effect = reducer.run(&n, (), ())
    let expectation = self.expectation(description: "effect")
    effect
      .sink(receiveCompletion: { _ in expectation.fulfill() }, receiveValue: { _ in })
      .store(in: &self.cancellables)
    self.wait(for: [expectation], timeout: 0.1)
  }

  func testDisabledSignpost() {
    let reducer = Reducer<Int, Void, Void>.empty.signpost(log: .disabled)
    var n = 0
    let effect = reducer.run(&n, (), ())
    let expectation = self.expectation(description: "effect")
    effect
      .sink(receiveCompletion: { _ in expectation.fulfill() }, receiveValue: { _ in })
      .store(in: &self.cancellables)
    self.wait(for: [expectation], timeout: 0.1)
  }

  func testNavigatesCollision() {

    struct ChildState: Equatable {
      var count = 0
    }
    enum ChildAction: Equatable {
      case onAppear
      case response(Int)
    }
    struct Environment {
      var mainQueue: AnySchedulerOf<DispatchQueue>
    }
    struct State: Equatable {
      var child: ChildState?
    }
    enum Action: Equatable {
      case child(PresentationAction<ChildAction>)
    }

    let childReducer = Reducer<ChildState, ChildAction, Environment> { state, action, environment in
      switch action {
      case .onAppear:
        return Effect(value: .response(42))
          .receive(on: environment.mainQueue)
          .eraseToEffect()

      case let .response(int):
        state.count = int
        return .none
      }
    }

    var sharedReducer: Reducer<State, Action, Environment> {
      Reducer<State, Action, Environment> { state, action, environment in
        switch action {
        case .child(.present):
          state.child = .init()
          return .none
          
        case .child:
          return .none
        }
      }
      .navigates(childReducer, state: \.child, action: /Action.child, environment: { $0 })
    }

    struct ParentState: Equatable {
      var state1 = State()
      var state2 = State()
    }
    enum ParentAction: Equatable {
      case state1(Action)
      case state2(Action)
    }

    let parentReducer = Reducer<ParentState, ParentAction, Environment>.combine(
      sharedReducer.pullback(state: \.state1, action: /ParentAction.state1, environment: { $0 }),
      sharedReducer.pullback(state: \.state2, action: /ParentAction.state2, environment: { $0 })
      )

    let mainQueue = DispatchQueue.test

    let store = TestStore(
      initialState: ParentState(),
      reducer: parentReducer,
      environment: Environment(mainQueue: mainQueue.eraseToAnyScheduler())
    )

    store.send(.state1(.child(.present))) {
      $0.state1.child = .init()
    }
    store.send(.state1(.child(.isPresented(.onAppear))))

    store.send(.state2(.child(.present))) {
      $0.state2.child = .init()
    }
    store.send(.state2(.child(.dismiss))) {
      $0.state2.child = nil
    }

    mainQueue.advance()
    // TODO: why does this take so long?
    store.receive(.state1(.child(.isPresented(.response(42))))) {
      $0.state1.child?.count = 42
    }
  }
}
