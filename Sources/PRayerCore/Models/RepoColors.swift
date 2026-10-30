import Foundation

/// 레포마다 색 하나를 **겹치지 않게** 나눠 준다. 실제 색(SwiftUI Color)은 앱의 팔레트가 정하고,
/// 여기서는 팔레트의 몇 번째 색인지만 정한다(위쪽 레포 탭의 점·밑줄, 행의 점·레포 칩이 이 색을 쓴다).
///
/// 예전에는 레포 이름 해시로 8색 중 하나를 골랐다. 이름만으로 정하니 레포가 늘면 두 레포가 같은 색을 받았다
/// (3개면 34%, 4개면 59% 확률). 색을 12개로 늘려도 4개면 43% 라, 늘리는 것과 함께 **나눠 준다**(사용자 결정):
/// 새 레포는 아직 아무도 안 쓴 색을 받고, 한 번 받은 색은 설정에 남겨 다른 레포를 넣고 빼도 바뀌지 않는다.
public enum RepoColors {
    /// 팔레트 크기. 앱의 팔레트(RepoDot)도 같은 길이다.
    public static let count = 12

    /// 빨강 계열 자리(분홍·빨강 — 앱 팔레트 RepoDot.palette 의 순서와 맞아야 한다).
    /// 레포 점이 빨갛게 보이면 "뭔가 잘못됐다" 는 신호로 읽힌다(실제로 물어 온 사람이 있었다 — 분홍도
    /// 작은 점에서는 빨강으로 보인다). 레포가 한둘인 사람은 늘 앞의 두 레포만 보므로, 거기에는 주지 않는다.
    public static let reddish: Set<Int> = [2, 11]
    /// 파랑 계열 자리(파랑·청록·남색·하늘 — 팔레트 순서와 맞아야 한다). 첫 레포 탭은 "전체" 탭 바로 옆이고
    /// 전체 탭의 숫자·고른 밑줄은 강조색(기본 파랑)이라, 첫 레포가 파랑 계열이면 같은 색 탭 둘이 붙어 보인다.
    public static let bluish: Set<Int> = [0, 5, 6, 9]

    /// 이 자리(설정의 레포 순서, 0부터)의 레포가 받지 않는 색. 첫 레포는 빨강·파랑 계열, 두 번째는 빨강 계열.
    public static func avoided(at position: Int) -> Set<Int> {
        switch position {
        case 0: return reddish.union(bluish)
        case 1: return reddish
        default: return []
        }
    }

    /// 색을 찾는 키 — 레포 이름(오너 빼고) 소문자. 행·탭이 이름만 들고 있어서다.
    /// 오너만 다른 같은 이름의 레포는 같은 색이 된다(드물고, 탭은 그때 전체 이름을 보인다).
    public static func key(_ name: String) -> String { name.lowercased() }

    /// 예전 규칙(이름 해시, 8색)의 자리. 새 팔레트의 앞 8색은 예전과 같은 순서라, 이미 그 색으로 익숙한 레포는
    /// 비어 있으면 그 색을 그대로 받는다 — 업데이트했다고 탭 색이 몽땅 바뀌지 않게.
    /// 실행을 넘어 늘 같아야 한다(String.hashValue 는 프로세스마다 시드가 달라진다).
    public static func legacyIndex(for name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % 8)
    }

    /// 지금 레포 목록(설정 순서)에 색을 나눠 준다.
    ///
    /// - Parameters:
    ///   - repos: 레포 이름들. 앞에 있는 레포가 먼저 고른다.
    ///   - existing: 지금까지 나눠 준 색(키 → 자리). 목록에 없는 레포의 기록은 버린다 — 그 색을 다음 레포가 쓰게.
    /// - Returns: 키 → 자리. 레포가 팔레트보다 많으면 그때부터는 겹칠 수밖에 없어 예전 규칙의 자리를 준다.
    public static func assign(repos: [String], existing: [String: Int]) -> [String: Int] {
        var seen = Set<String>()
        let keys = repos.map(key).filter { seen.insert($0).inserted }
        var result: [String: Int] = [:]
        var used = Set<Int>()
        // 앞자리 레포는 피하는 색이 있다(avoided). 예전에 받아 둔 색이라도 그 자리에서 피하는 색이면 내려놓고 다시 받는다.
        func allowed(_ index: Int, at position: Int) -> Bool {
            !avoided(at: position).contains(index)
        }
        // 이미 받은 색은 그대로 둔다. 손으로 고친 설정 등으로 둘이 같은 색을 들고 있으면 앞의 것만 남기고
        // 뒤의 것은 아래에서 다시 나눈다.
        for (position, key) in keys.enumerated() {
            guard let index = existing[key], (0..<count).contains(index), !used.contains(index),
                  allowed(index, at: position) else { continue }
            result[key] = index
            used.insert(index)
        }
        for (position, key) in keys.enumerated() where result[key] == nil {
            let legacy = legacyIndex(for: key)
            let free = { (index: Int) in !used.contains(index) && allowed(index, at: position) }
            let index = free(legacy) ? legacy : ((0..<count).first(where: free) ?? legacy)
            result[key] = index
            used.insert(index)
        }
        return result
    }
}
