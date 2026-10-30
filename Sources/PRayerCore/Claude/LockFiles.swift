import Foundation

/// 리뷰에서 늘 빼는 잠금 파일. 사용자가 고르지 않는다 — 고르게 하면 귀찮다(사용자 결정).
///
/// 잠금 파일은 패키지 관리자가 만들고 고치는 파일이라 사람이 리뷰할 내용이 없고, 의존성 버전을 올리면 수백 줄이
/// 바뀐다(실측: 최근 PR 204개 중 27개에 들어 있었고 2,175줄). 어떤 의존성이 바뀌었는지는 짝이 되는 선언 파일
/// (Package.swift·package.json·Podfile·build.gradle …)의 diff 에 보인다.
///
/// 파일 이름 그대로 알아본다. 분야마다 패키지 관리자의 잠금 파일 이름은 정해져 있어 AI 없이 고정 목록으로 된다.
/// 리뷰에는 이름과 줄 수만 알린다(`PromptBuilder` 의 excluded_files). 변경 파일 탭에서는 '제외됨' 아래에서 볼 수 있다.
public enum LockFiles {
    public static let names: Set<String> = [
        // JavaScript·TypeScript
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "deno.lock",
        // Python
        "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock",
        // Ruby·PHP
        "Gemfile.lock", "composer.lock",
        // Go·Rust
        "go.sum", "go.work.sum", "Cargo.lock",
        // JVM·Android·.NET
        "gradle.lockfile", "buildscript-gradle.lockfile", "packages.lock.json",
        // Apple
        "Package.resolved", "Podfile.lock", "Cartfile.resolved",
        // Dart·Elixir·Erlang
        "pubspec.lock", "mix.lock", "rebar.lock",
        // 인프라·빌드
        ".terraform.lock.hcl", "flake.lock", "MODULE.bazel.lock",
        // R·Haskell·Perl
        "renv.lock", "stack.yaml.lock", "cabal.project.freeze", "cpanfile.snapshot",
    ]

    public static func isLockFile(_ path: String) -> Bool {
        names.contains((path as NSString).lastPathComponent)
    }
}
