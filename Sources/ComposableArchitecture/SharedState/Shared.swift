import CustomDump
import Dependencies
import XCTestDynamicOverlay

public enum None<Value>: PersistenceReaderKey {
  public func load(initialValue: Value?) -> Value? { nil }
  case none
}
extension None: PersistenceKey {
  public func save(_ value: Value) {}
}

#if canImport(Combine)
  import Combine
#endif

/// A property wrapper type that shares a value with multiple parts of an application.
///
/// See the <doc:SharingState> article for more detailed information on how to use this property
/// wrapper.
@dynamicMemberLookup
@propertyWrapper
public struct Shared<Value, Persistence: PersistenceKey<Value>> {
  private let reference: any Reference
  private let keyPath: AnyKeyPath
  private let _persistence: Persistence?

  public var wrappedValue: Value {
    get {
      @Dependency(SharedChangeTrackerKey.self) var changeTracker
      if changeTracker?.isAsserting == true {
        return self.snapshot ?? self.currentValue
      } else {
        return self.currentValue
      }
    }
    nonmutating set {
      @Dependency(SharedChangeTrackerKey.self) var changeTracker
      if changeTracker?.isAsserting == true {
        self.snapshot = newValue
      } else {
        changeTracker?.track(self.reference)
        self.currentValue = newValue
      }
    }
  }

  /// A projection of the shared value that returns a shared reference.
  ///
  /// Use the projected value to pass a shared value down to another feature. This is most
  /// commonly done to share a value from one feature to another:
  ///
  /// ```swift
  /// case .nextButtonTapped:
  ///   state.path.append(
  ///     PersonalInfoFeature(signUpData: state.$signUpData)
  ///   )
  /// ```
  ///
  /// Further you can use dot-chaining syntax to derive a smaller piece of shared state to hand
  /// to another feature:
  ///
  /// ```swift
  /// case .nextButtonTapped:
  ///   state.path.append(
  ///     PhoneNumberFeature(phoneNumber: state.$signUpData.phoneNumber)
  ///   )
  /// ```
  ///
  /// See <doc:SharingState#Deriving-shared-state> for more details.
  public var projectedValue: Shared {
    get { self }
    set { self = newValue }
  }

  #if canImport(Combine)
    public var publisher: AnyPublisher<Value, Never> {
      func open<Root>(_ reference: some Reference<Root>) -> AnyPublisher<Value, Never> {
        reference.publisher
          .map { $0[keyPath: unsafeDowncast(self.keyPath, to: KeyPath<Root, Value>.self)] }
          .eraseToAnyPublisher()
      }
      return open(self.reference)
    }
  #endif

  init(reference: any Reference, keyPath: AnyKeyPath, persistence: Persistence?) {
    self.reference = reference
    self.keyPath = keyPath
    self._persistence = persistence
  }

//  public init(projectedValue: Shared) {
//    self = projectedValue
//  }

  public subscript<Member>(
    dynamicMember keyPath: WritableKeyPath<Value, Member>
  ) -> Shared<Member, None<Member>> {
    Shared<Member, None<Member>>(
      reference: self.reference,
      keyPath: self.keyPath.appending(path: keyPath)!,
      persistence: nil
    )
  }

  public subscript<Member>(
    dynamicMember keyPath: WritableKeyPath<Value, Member?>
  ) -> Shared<Member, None<Member>>? {
    guard let initialValue = self.wrappedValue[keyPath: keyPath]
    else { return nil }
    return Shared<Member, None<Member>>(
      reference: self.reference,
      keyPath: self.keyPath.appending(
        path: keyPath.appending(path: \.[default:DefaultSubscript(initialValue)])
      )!,
      persistence: nil
    )
  }

  public func assert(
    _ updateValueToExpectedResult: (inout Value) throws -> Void,
    file: StaticString = #file,
    line: UInt = #line
  ) rethrows where Value: Equatable {
    @Dependency(SharedChangeTrackerKey.self) var changeTracker
    guard let changeTracker
    else {
      XCTFail(
        "Use 'withSharedChangeTracking' to track changes to assert against.",
        file: file,
        line: line
      )
      return
    }
    let wasAsserting = changeTracker.isAsserting
    changeTracker.isAsserting = true
    defer { changeTracker.isAsserting = wasAsserting }
    guard var snapshot = self.snapshot, snapshot != self.currentValue else {
      XCTFail("Expected changes, but none occurred.", file: file, line: line)
      return
    }
    try updateValueToExpectedResult(&snapshot)
    self.snapshot = snapshot
    // TODO: Finesse error more than `XCTAssertNoDifference`
    XCTAssertNoDifference(self.currentValue, self.snapshot, file: file, line: line)
    self.snapshot = nil
  }

  private var currentValue: Value {
    get {
      func open<Root>(_ reference: some Reference<Root>) -> Value {
        reference.value[
          keyPath: unsafeDowncast(self.keyPath, to: KeyPath<Root, Value>.self)
        ]
      }
      return open(self.reference)
    }
    nonmutating set {
      func open<Root>(_ reference: some Reference<Root>) {
        reference.value[
          keyPath: unsafeDowncast(self.keyPath, to: WritableKeyPath<Root, Value>.self)
        ] = newValue
      }
      return open(self.reference)
    }
  }

  private var snapshot: Value? {
    get {
      func open<Root>(_ reference: some Reference<Root>) -> Value? {
        @Dependency(SharedChangeTrackerKey.self) var changeTracker
        return changeTracker?[reference]?.snapshot[
          keyPath: unsafeDowncast(self.keyPath, to: WritableKeyPath<Root, Value>.self)
        ]
      }
      return open(self.reference)
    }
    nonmutating set {
      func open<Root>(_ reference: some Reference<Root>) {
        @Dependency(SharedChangeTrackerKey.self) var changeTracker
        guard let newValue else {
          changeTracker?[reference] = nil
          return
        }
        if changeTracker?[reference] == nil {
          changeTracker?[reference] = AnyChange(reference)
        }
        changeTracker?[reference]?.snapshot[
          keyPath: unsafeDowncast(self.keyPath, to: WritableKeyPath<Root, Value>.self)
        ] = newValue
      }
      return open(self.reference)
    }
  }
}

extension Shared: @unchecked Sendable where Value: Sendable {}

extension Shared: Equatable where Value: Equatable {
  public static func == (lhs: Shared, rhs: Shared) -> Bool {
    @Dependency(SharedChangeTrackerKey.self) var changeTracker
    if changeTracker?.isAsserting == true, lhs.reference === rhs.reference {
      if let lhsReference = lhs.reference as? any Equatable {
        func open<T: Equatable>(_ lhsReference: T) -> Bool {
          lhsReference == rhs.reference as? T
        }
        return open(lhsReference)
      }
      return lhs.snapshot ?? lhs.currentValue == rhs.currentValue
    } else {
      return lhs.wrappedValue == rhs.wrappedValue
    }
  }
}

extension Shared: Hashable where Value: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.wrappedValue)
    // TODO: hash reference too?
    // TODO: or should we only hash reference?
  }
}

extension Shared: Identifiable where Value: Identifiable {
  public var id: Value.ID {
    self.wrappedValue.id
  }
}

extension Shared: Encodable where Value: Encodable {
  public func encode(to encoder: Encoder) throws {
    do {
      var container = encoder.singleValueContainer()
      try container.encode(self.wrappedValue)
    } catch {
      try self.wrappedValue.encode(to: encoder)
    }
  }
}

extension Shared: CustomDumpRepresentable {
  public var customDumpValue: Any {
    self.currentValue
  }
}

extension Shared: _CustomDiffObject {
  public var _customDiffValues: (Any, Any) {
    (self.snapshot ?? self.currentValue, self.currentValue)
  }

  public var _objectIdentifier: ObjectIdentifier {
    ObjectIdentifier(self.reference)
  }
}

extension Shared
where Value: RandomAccessCollection & MutableCollection, Value.Index: Hashable & Sendable {
  /// Derives a collection of shared elements from a shared collection of elements.
  ///
  /// This can be useful when used in conjunction with `ForEach` in order to derive a shared
  /// reference for each element of a collection:
  ///
  /// ```swift
  /// struct State {
  ///   @Shared(.fileStorage(.todos)) var todos: IdentifiedArrayOf<Todo> = []
  ///   // ...
  /// }
  ///
  /// // ...
  ///
  /// ForEach(store.$todos.elements) { $todo in
  ///   NavigationLink(
  ///     // $todo: Shared<Todo>
  ///     //  todo: Todo
  ///     state: Path.State.todo(TodoFeature.State(todo: $todo))
  ///   ) {
  ///     Text(todo.title)
  ///   }
  /// }
  /// ```
  public var elements: some RandomAccessCollection<Shared<Value.Element, None<Value.Element>>> {
    zip(self.wrappedValue.indices, self.wrappedValue).lazy.map { index, element in
      self[index, default: DefaultSubscript(element)]
    }
  }
}

extension Shared {
  public subscript<Member>(
    dynamicMember keyPath: KeyPath<Value, Member>
  ) -> SharedReader<Member> {
    SharedReader<Member>(
      reference: self.reference,
      keyPath: self.keyPath.appending(path: keyPath)!
    )
  }

  public var reader: SharedReader<Value> {
    SharedReader(reference: self.reference, keyPath: self.keyPath)
  }

  public subscript<Member>(
    dynamicMember keyPath: KeyPath<Value, Member?>
  ) -> SharedReader<Member>? {
    guard let initialValue = self.wrappedValue[keyPath: keyPath]
    else { return nil }
    return SharedReader<Member>(
      reference: self.reference,
      keyPath: self.keyPath.appending(
        path: keyPath.appending(path: \.[default:DefaultSubscript(initialValue)])
      )!
    )
  }
}

extension Shared where Persistence: PersistenceReaderKey, Persistence.Value == Value {
  public var persistence: Persistence { self._persistence! }
}


struct ServerConfig {
  var identifier = ""
}
struct ServerConfigKey: PersistenceKey, Hashable {
  func load(initialValue: ServerConfig?) -> ServerConfig? {
    nil
  }
  func save(_ value: ServerConfig) {
  }
  func reload() {}
}

extension Shared {
  public init(value: Value, fileID: StaticString = #fileID, line: UInt = #line) where Persistence == None<Value> {
    self.init(
      reference: ValueReference<Value, None<Value>>(
        initialValue: value,
        fileID: fileID,
        line: line
      ),
      keyPath: \Value.self,
      persistence: None<Value>.none
    )
  }
  public enum Something { case unspecified }
  public init(_: Something) where Persistence == None<Value> {
    fatalError()
  }
  public init() where Persistence == None<Value> {
    fatalError()
  }
}




struct State1 {
//  @Shared(.)
//  @Shared var
//  @Shared(.unspecified) var count: Int
//@Shared(.local) var count: Int

//  @Shared(.appst)

  //@Shared(<#T##persistenceKey: Persistence##Persistence#>)

//  @Shared(wrappedValue: 1, .a)

  @Shared(.appStorage("count")) var count = 0

  @Shared(.unspecified) var outsideCount: Int
  @Shared() var z: Int
  //@Shared var x: Int

  init(
    count: Int = 0,
    outsideCount: Shared<Int, None<Int>>,
    z: Int
  ) {
    self.count = count
    self._outsideCount = outsideCount
    self.z = z
  }


  func foo() {
    //State1.init(count: <#T##Int#>, outsideCount: <#T##Shared<Int, None<Int>>#>, z: <#T##Shared<Int, None<Int>>#>)
  }
}




//typealias SimpleShared<Value> = Shared<Value, Never>
