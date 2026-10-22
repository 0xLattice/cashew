import ArrayTrie

public extension MerkleDictionary {
    func transform(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> Self? {
        // No entry can live at the empty key: the children are keyed by a
        // first character, so a write there would move `count` and nothing else.
        if transforms.traverse([""]) != nil { throw TransformErrors.invalidKey("empty key") }
        let values = transforms.childValues()
        var delta = 0
        for value in values {
            switch value {
                case .delete: delta -= 1
                case .insert(_): delta += 1
                default: continue
            }
        }
        var newChildren = [Character: ChildType]()
        let allChildChars = Set(transforms.childCharacters()).union(properties().map { $0.first! })
        for childChar in allChildChars {
            if let existingChild = children[childChar] {
                if let traversal = transforms.traverseChild(childChar) {
                    if let traversedChild = try existingChild.transform(transforms: traversal, keyProvider: keyProvider) {
                        newChildren[childChar] = traversedChild
                    }
                    else {
                        newChildren.removeValue(forKey: childChar)
                    }
                }
                else {
                    newChildren[childChar] = existingChild
                }
            }
            else {
                guard let traversal = transforms.traverseChild(childChar) else { throw TransformErrors.transformFailed("no traversal for new child '\(childChar)'") }
                if !traversal.isEmpty {
                    let newChild = try ChildType.NodeType.insertAll(childChar: childChar, transforms: traversal)
                    newChildren[childChar] = try ChildType(node: newChild)
                }
            }
        }
        return Self(children: newChildren, count: count + delta)
    }

    func deleting(key: String, keyProvider: KeyProvider?) throws -> Self {
        guard let firstChar = key.first else { throw TransformErrors.invalidKey("empty key") }
        if let existingChild = children[firstChar] {
            if let updatedChild = try existingChild.deleting(key: ArraySlice(key), keyProvider: keyProvider) {
                var newChildren = children
                newChildren[firstChar] = updatedChild
                return Self(children: newChildren, count: count - 1)
            }
            var newChildren = children
            newChildren.removeValue(forKey: firstChar)
            return Self(children: newChildren, count: count - 1)
        }
        else {
            throw TransformErrors.invalidKey("key '\(key)' not found")
        }
    }

    func mutating(key: String, value: ValueType, keyProvider: KeyProvider?) throws -> Self {
        return try mutating(key: ArraySlice(key), value: value, keyProvider: keyProvider)
    }

    func mutating(key: ArraySlice<Character>, value: ValueType, keyProvider: KeyProvider?) throws -> Self {
        guard let firstChar = key.first else { throw TransformErrors.invalidKey("empty key") }
        if let existingChild = children[firstChar] {
            let updatedChild = try existingChild.mutating(key: key, value: value, keyProvider: keyProvider)
            var newChildren = children
            newChildren[firstChar] = updatedChild
            return Self(children: newChildren, count: count)
        } else {
            throw TransformErrors.invalidKey("key '\(String(key))' not found")
        }
    }

    func get(key: String) throws -> ValueType? {
        guard let firstChar = key.first else { return nil }
        guard let existingChild = children[firstChar] else { return nil }
        return try existingChild.get(key: ArraySlice(key))
    }
    
    func deleting(key: String) throws -> Self {
        guard let firstChar = key.first else { throw TransformErrors.invalidKey("empty key") }
        if let existingChild = children[firstChar] {
            if let updatedChild = try existingChild.deleting(key: ArraySlice(key)) {
                var newChildren = children
                newChildren[firstChar] = updatedChild
                return Self(children: newChildren, count: count - 1)
            }
            var newChildren = children
            newChildren.removeValue(forKey: firstChar)
            return Self(children: newChildren, count: count - 1)
        }
        else {
            throw TransformErrors.invalidKey("key '\(key)' not found")
        }
    }
    
    func inserting(key: String, value: ValueType) throws -> Self {
        if key == "" { throw TransformErrors.invalidKey("empty key") }
        return try inserting(key: ArraySlice(key), value: value)
    }

    func inserting(key: ArraySlice<Character>, value: ValueType) throws -> Self {
        guard let firstChar = key.first else { throw TransformErrors.invalidKey("empty key") }
        if let existingChild = children[firstChar] {
            let updatedChild = try existingChild.inserting(key: key, value: value)
            var newChildren = children
            newChildren[firstChar] = updatedChild
            return Self(children: newChildren, count: count + 1)
        } else {
            let newChild = try ChildType(node: ChildType.NodeType(prefix: String(key), value: value, children: [:]))
            var newChildren = children
            newChildren[firstChar] = newChild
            return Self(children: newChildren, count: count + 1)
        }
    }
    
    func mutating(key: String, value: ValueType) throws -> Self {
        return try mutating(key: ArraySlice(key), value: value)
    }
    
    func mutating(key: ArraySlice<Character>, value: ValueType) throws -> Self {
        guard let firstChar = key.first else { throw TransformErrors.invalidKey("empty key") }
        if let existingChild = children[firstChar] {
            let updatedChild = try existingChild.mutating(key: key, value: value)
            var newChildren = children
            newChildren[firstChar] = updatedChild
            return Self(children: newChildren, count: count)
        } else {
            throw TransformErrors.invalidKey("key '\(String(key))' not found")
        }
    }

}
