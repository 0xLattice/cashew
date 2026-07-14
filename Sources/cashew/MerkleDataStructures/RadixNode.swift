/// An internal node in the compressed radix trie that backs ``MerkleDictionary``.
///
/// Each node stores a `prefix` (the compressed edge label), an optional `value`,
/// and a map of child nodes keyed by the next character. The trie is path-compressed:
/// chains of single-child nodes are collapsed into a single node with a longer prefix.
public protocol RadixNode: Node {
    associatedtype ChildType: RadixHeader where ChildType.NodeType == Self
    associatedtype ValueType: LosslessStringConvertible
    
    var prefix: String { get }
    var value: ValueType? { get }
    var children: [Character: ChildType] { get }
    
    init(prefix: String, value: ValueType?, children: [Character: ChildType])
}

public extension RadixNode {
    func set(properties: [PathSegment : any Header]) -> Self {
        var newProperties = [Character: ChildType]()
        for property in properties.keys {
            newProperties.updateValue(properties[property] as! ChildType, forKey: property.first!)
        }
        return Self(prefix: prefix, value: value, children: newProperties)
    }
    
    func set(properties: [Character: ChildType]) -> Self {
        return Self(prefix: prefix, value: value, children: properties)
    }
    
    func get(property: PathSegment) -> (any Header)? {
        guard let char = property.first else { return nil }
        return children[char]
    }

    func getChild(property: PathSegment) -> ChildType {
        return children[property.first!]!
    }
    
    func properties() -> Set<PathSegment> {
        return Set(children.keys.map({ character in String(character) }))
    }
    
    func set(property: PathSegment, to child: any Header) -> Self {
        guard let typedChild = child as? ChildType, let char = property.first else { return self }
        var newChildren = children
        newChildren[char] = typedChild
        return Self(prefix: prefix, value: value, children: newChildren)
    }
}
