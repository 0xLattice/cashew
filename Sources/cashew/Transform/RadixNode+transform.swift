import ArrayTrie

public extension RadixNode {
    func collapsed(prefix pfx: String, children: [Character: ChildType]) throws -> Self? {
        if children.isEmpty { return nil }
        if children.count == 1 {
            guard let child = children.first?.value.node else { throw TransformErrors.transformFailed("no child node during collapse at prefix '\(pfx)'") }
            return Self(prefix: pfx + child.prefix, value: child.value, children: child.children)
        }
        return Self(prefix: pfx, value: nil, children: children)
    }

    /// Whether the batch writes beneath the value at `key`: multi-segment
    /// paths into a nested dictionary held there.
    static func hasNestedWrites(at key: String, in transforms: ArrayTrie<Transform>) -> Bool {
        guard let beneath = transforms.traverse([key])?.deleting(path: []) else { return false }
        return !beneath.isEmpty
    }

    static func insertAll(childChar: Character, transforms: ArrayTrie<Transform>) throws -> Self {
        guard let childPrefix = transforms.childPrefix(for: childChar) else { throw TransformErrors.transformFailed("no child prefix for '\(childChar)' in insertAll") }
        guard let traversedTransforms = transforms.traverse(path: childPrefix) else { throw TransformErrors.transformFailed("traversal failed for prefix '\(childPrefix)' in insertAll") }
        var newProperties = [Character: ChildType]()
        for childChar in traversedTransforms.childCharacters() {
            guard let traversedChild = traversedTransforms.traverseChild(childChar) else { throw TransformErrors.transformFailed("failed to traverse child '\(childChar)' in insertAll") }
            if traversedChild.isEmpty { throw TransformErrors.transformFailed("empty traversed child for '\(childChar)' in insertAll") }
            newProperties[childChar] = try ChildType(node: insertAll(childChar: childChar, transforms: traversedChild))
        }
        if hasNestedWrites(at: childPrefix, in: transforms) {
            throw TransformErrors.invalidKey("nested write beneath missing key '\(childPrefix)'")
        }
        if case .insert(let newValue) = traversedTransforms.get([""]) {
            guard let newValue = ValueType(newValue) else { throw TransformErrors.transformFailed("failed to parse inserted value at prefix '\(childPrefix)'") }
            return Self(prefix: childPrefix, value: newValue, children: newProperties)
        } else if traversedTransforms.get([""]) != nil {
            throw TransformErrors.transformFailed("non-insert transform at leaf in insertAll for prefix '\(childPrefix)'")
        }
        return Self(prefix: childPrefix, value: nil, children: newProperties)
    }

    func transform(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> Self? {
        guard let childPrefix = transforms.childPrefix(for: prefix.first!) else { throw TransformErrors.transformFailed("no child prefix for '\(prefix.first!)' in transform") }
        let childPrefixSlice = ArraySlice(childPrefix)
        let prefixSlice = ArraySlice(prefix)
        let comparison = compareSlices(childPrefixSlice, prefixSlice)

        switch comparison {
        case 0:
            return try transformExactMatch(transforms: transforms, childPrefix: childPrefix, keyProvider: keyProvider)
        case 1:
            return try transformChildLonger(transforms: transforms, childPrefixSlice: childPrefixSlice, keyProvider: keyProvider)
        case 2:
            return try transformPrefixLonger(transforms: transforms, childPrefix: childPrefix, prefixSlice: prefixSlice, keyProvider: keyProvider)
        default:
            return try transformDivergent(transforms: transforms, prefixSlice: prefixSlice, childPrefixSlice: childPrefixSlice, keyProvider: keyProvider)
        }
    }

    private func transformExactMatch(transforms: ArrayTrie<Transform>, childPrefix: String, keyProvider: KeyProvider?) throws -> Self? {
        guard let traversedChild = transforms.traverse(path: childPrefix) else { throw TransformErrors.transformFailed("traversal failed for prefix '\(childPrefix)' in transformExactMatch") }

        if let transform = traversedChild.get([""]) {
            if Self.hasNestedWrites(at: childPrefix, in: transforms) {
                throw TransformErrors.transformFailed("ambiguous transform: a value write and nested writes at '\(prefix)'")
            }
            switch transform {
            case .update(let newValue):
                if value == nil { throw TransformErrors.invalidKey("cannot update: no value at prefix '\(prefix)'") }
                let newChildren = try transformChildren(transforms: traversedChild, keyProvider: keyProvider)
                guard let newValue = ValueType(newValue) else { throw TransformErrors.transformFailed("failed to parse update value at prefix '\(prefix)'") }
                return Self(prefix: prefix, value: newValue, children: newChildren)
            case .delete:
                if value == nil { throw TransformErrors.invalidKey("cannot delete: no value at prefix '\(prefix)'") }
                let newChildren = try transformChildren(transforms: traversedChild, keyProvider: keyProvider)
                return try collapsed(prefix: prefix, children: newChildren)
            case .insert(let newValue):
                if value != nil { throw TransformErrors.transformFailed("cannot insert: value already exists at prefix '\(prefix)'") }
                let newChildren = try transformChildren(transforms: traversedChild, keyProvider: keyProvider)
                guard let newValue = ValueType(newValue) else { throw TransformErrors.transformFailed("failed to parse insert value at prefix '\(prefix)'") }
                return Self(prefix: prefix, value: newValue, children: newChildren)
            }
        }

        let newChildren = traversedChild.isEmpty ? children : try transformChildren(transforms: traversedChild, keyProvider: keyProvider)

        if let traversedNext = transforms.traverse([childPrefix]), !traversedNext.isEmpty {
            guard let address = value as? any Header else {
                if value != nil { throw TransformErrors.invalidKey("value at prefix '\(prefix)' is not a Header") }
                throw TransformErrors.invalidKey("nested write beneath missing key '\(prefix)'")
            }
            guard let newValue = try address.transform(transforms: traversedNext, keyProvider: keyProvider) else {
                return try collapsed(prefix: prefix, children: newChildren)
            }
            guard let typedValue = newValue as? ValueType else { throw TransformErrors.transformFailed("transformed Header value type mismatch at prefix '\(prefix)'") }
            return Self(prefix: prefix, value: typedValue, children: newChildren)
        }

        if value != nil {
            return Self(prefix: prefix, value: value, children: newChildren)
        }
        return try collapsed(prefix: prefix, children: newChildren)
    }

    private func transformChildLonger(transforms: ArrayTrie<Transform>, childPrefixSlice: ArraySlice<Character>, keyProvider: KeyProvider?) throws -> Self? {
        let remainingChildPrefix = childPrefixSlice.dropFirst(prefix.count)
        guard let traversedChild = transforms.traverse(path: prefix) else { throw TransformErrors.transformFailed("traversal failed for prefix '\(prefix)' in transformChildLonger") }
        let childChar = remainingChildPrefix.first!

        guard let child = children[childChar] else {
            let newChild = try Self.insertAll(childChar: childChar, transforms: traversedChild)
            var newChildren = children
            newChildren[childChar] = try ChildType(node: newChild)
            return Self(prefix: prefix, value: value, children: newChildren)
        }

        guard let childNode = child.node else { throw TransformErrors.missingData("child node not loaded for '\(childChar)' at prefix '\(prefix)'") }
        guard let newChild = try childNode.transform(transforms: traversedChild, keyProvider: keyProvider) else {
            var newChildren = children
            newChildren.removeValue(forKey: childChar)
            if value != nil {
                return Self(prefix: prefix, value: value, children: newChildren)
            }
            return try collapsed(prefix: prefix, children: newChildren)
        }

        var newChildren = children
        newChildren[childChar] = try child.reEncryptIfNeeded(node: newChild, keyProvider: keyProvider)
        return Self(prefix: prefix, value: value, children: newChildren)
    }

    private func transformPrefixLonger(transforms: ArrayTrie<Transform>, childPrefix: String, prefixSlice: ArraySlice<Character>, keyProvider: KeyProvider?) throws -> Self? {
        let remainingPrefix = prefixSlice.dropFirst(childPrefix.count)
        guard let existingNodeChar = remainingPrefix.first else { throw TransformErrors.transformFailed("empty remaining prefix after split at '\(childPrefix)'") }
        guard let traversedChild = transforms.traverse(path: childPrefix) else { throw TransformErrors.transformFailed("traversal failed for prefix '\(childPrefix)' in transformPrefixLonger") }
        var newChildren = [Character: ChildType]()
        var existingNodeHandled = false

        for childChar in traversedChild.childCharacters() {
            guard let childTransform = traversedChild.traverseChild(childChar) else { throw TransformErrors.transformFailed("failed to traverse child '\(childChar)' in transformPrefixLonger") }
            if childChar == existingNodeChar {
                existingNodeHandled = true
                if let newChild = try Self(prefix: String(remainingPrefix), value: value, children: children).transform(transforms: childTransform, keyProvider: keyProvider) {
                    newChildren[childChar] = try ChildType(node: newChild)
                }
            } else {
                newChildren[childChar] = try ChildType(node: Self.insertAll(childChar: childChar, transforms: childTransform))
            }
        }

        if !existingNodeHandled {
            newChildren[existingNodeChar] = try ChildType(node: Self(prefix: String(remainingPrefix), value: value, children: children))
        }

        if Self.hasNestedWrites(at: childPrefix, in: transforms) {
            throw TransformErrors.invalidKey("nested write beneath missing key '\(childPrefix)'")
        }
        if case .insert(let newValue) = traversedChild.get([""]) {
            guard let newValue = ValueType(newValue) else { throw TransformErrors.transformFailed("failed to parse insert value at prefix '\(childPrefix)' in transformPrefixLonger") }
            return Self(prefix: childPrefix, value: newValue, children: newChildren)
        } else if traversedChild.get([""]) != nil {
            throw TransformErrors.transformFailed("non-insert transform at leaf in transformPrefixLonger for prefix '\(childPrefix)'")
        }

        return try collapsed(prefix: childPrefix, children: newChildren)
    }

    private func transformDivergent(transforms: ArrayTrie<Transform>, prefixSlice: ArraySlice<Character>, childPrefixSlice: ArraySlice<Character>, keyProvider: KeyProvider?) throws -> Self? {
        let common = commonPrefixString(prefixSlice, childPrefixSlice)
        let prefixRemainder = String(prefixSlice.dropFirst(common.count))
        let childPrefixRemainder = String(childPrefixSlice.dropFirst(common.count))
        guard let childTransforms = transforms.traverse(path: common)?.traverseChild(childPrefixRemainder.first!) else { throw TransformErrors.transformFailed("traversal failed for divergent prefix common='\(common)' childRemainder='\(childPrefixRemainder)'") }
        let newChild = try Self.insertAll(childChar: childPrefixRemainder.first!, transforms: childTransforms)
        return Self(prefix: common, value: nil, children: [
            childPrefixRemainder.first!: try ChildType(node: newChild),
            prefixRemainder.first!: try ChildType(node: Self(prefix: prefixRemainder, value: value, children: children))
        ])
    }

    func transformChildren(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> [Character: ChildType] {
        var newChildren = [Character: ChildType]()
        for childChar in Set(transforms.childCharacters()).union(children.keys) {
            guard let transformChild = transforms.traverseChild(childChar) else {
                guard let currentChild = children[childChar] else { throw TransformErrors.transformFailed("no child at '\(childChar)' and no transform available in transformChildren") }
                newChildren[childChar] = currentChild
                continue
            }
            guard let currentChild = children[childChar] else {
                newChildren[childChar] = try ChildType(node: Self.insertAll(childChar: childChar, transforms: transformChild))
                continue
            }
            if let transformedChild = try currentChild.transform(transforms: transformChild, keyProvider: keyProvider) {
                newChildren[childChar] = transformedChild
            }
        }
        return newChildren
    }

    func get(key: ArraySlice<Character>) throws -> ValueType? {
        let prefixSlice = ArraySlice(prefix)
        if key.elementsEqual(prefixSlice) { return value }
        guard key.starts(with: prefixSlice) else { return nil }
        let newKey = key.dropFirst(prefixSlice.count)
        guard let childChar = newKey.first else { return value }
        guard let child = children[childChar] else { return nil }
        guard let childNode = child.node else { throw TransformErrors.missingData("child node not loaded for key '\(String(key))'") }
        return try childNode.get(key: newKey)
    }

    func deleting(key: ArraySlice<Character>) throws -> Self? {
        let prefixSlice = ArraySlice(prefix)
        let comparison = compareSlices(key, prefixSlice)
        switch comparison {
        case 0:
            if value == nil { throw TransformErrors.invalidKey("cannot delete: no value at prefix '\(prefix)'") }
            return try collapsed(prefix: prefix, children: children)
        case 1:
            let newKey = key.dropFirst(prefixSlice.count)
            let childChar = newKey.first!
            guard let child = children[childChar] else { throw TransformErrors.invalidKey("key '\(String(key))' not found at child '\(childChar)'") }
            if let newChild = try child.deleting(key: newKey) {
                var newChildren = children
                newChildren[childChar] = newChild
                return Self(prefix: prefix, value: value, children: newChildren)
            }
            if children.count == 1 && value == nil { return nil }
            var newChildren = children
            newChildren.removeValue(forKey: childChar)
            if newChildren.count == 1 && value == nil {
                guard let childNode = newChildren.first?.value.node else { throw TransformErrors.missingData("remaining child node not loaded during delete collapse at prefix '\(prefix)'") }
                return Self(prefix: prefix + childNode.prefix, value: childNode.value, children: childNode.children)
            }
            return Self(prefix: prefix, value: value, children: newChildren)
        default:
            throw TransformErrors.invalidKey("key '\(String(key))' does not match prefix '\(prefix)' for deletion")
        }
    }

    func mutating(key: ArraySlice<Character>, value: ValueType) throws -> Self {
        let selfPathSlice = ArraySlice(prefix)
        let comparison = compareSlices(key, selfPathSlice)
        switch comparison {
        case 0:
            if self.value == nil { throw TransformErrors.invalidKey("no value to mutate at prefix '\(prefix)'") }
            return Self(prefix: prefix, value: value, children: children)
        case 1:
            let keyRemainder = key.dropFirst(selfPathSlice.count)
            let keyChar = keyRemainder.first!
            guard let child = children[keyChar] else { throw TransformErrors.invalidKey("key '\(String(key))' not found at child '\(keyChar)'") }
            let updatedChild = try child.mutating(key: keyRemainder, value: value)
            var newChildren = children
            newChildren[keyChar] = updatedChild
            return Self(prefix: prefix, value: self.value, children: newChildren)
        default:
            throw TransformErrors.invalidKey("key '\(String(key))' does not match prefix '\(prefix)' for mutation")
        }
    }

    func inserting(key: ArraySlice<Character>, value: ValueType) throws -> Self {
        let selfPathSlice = ArraySlice(prefix)
        let comparison = compareSlices(key, selfPathSlice)
        switch comparison {
        case 0:
            if self.value != nil { throw TransformErrors.invalidKey("cannot insert: value already exists at prefix '\(prefix)'") }
            return Self(prefix: prefix, value: value, children: children)
        case 1:
            let keyRemainder = key.dropFirst(selfPathSlice.count)
            let keyChar = keyRemainder.first!
            if let child = children[keyChar] {
                let updatedChild = try child.inserting(key: keyRemainder, value: value)
                var newChildren = children
                newChildren[keyChar] = updatedChild
                return Self(prefix: prefix, value: self.value, children: newChildren)
            } else {
                let newChild = try ChildType(node: Self(prefix: String(keyRemainder), value: value, children: [:]))
                var newChildren = children
                newChildren[keyChar] = newChild
                return Self(prefix: prefix, value: self.value, children: newChildren)
            }
        case 2:
            let remainingPath = String(selfPathSlice.dropFirst(key.count))
            let existingChild = try ChildType(node: Self(prefix: remainingPath, value: self.value, children: children))
            return Self(prefix: String(key), value: value, children: [remainingPath.first!: existingChild])
        default:
            let common = commonPrefixString(key, selfPathSlice)
            let keyRemainder = String(key.dropFirst(common.count))
            let pathRemainder = String(selfPathSlice.dropFirst(common.count))
            let existingChild = try ChildType(node: Self(prefix: pathRemainder, value: self.value, children: children))
            let newChild = try ChildType(node: Self(prefix: keyRemainder, value: value, children: [:]))
            return Self(prefix: common, value: nil, children: [pathRemainder.first!: existingChild, keyRemainder.first!: newChild])
        }
    }
}
