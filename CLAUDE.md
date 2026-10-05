# supabase-defold - Claude Agent Guide

Defold 용 순수 Lua Supabase 클라이언트 라이브러리. 사용자 문서는 `README.md` (영문).

## 구조
- `supabase/`: 라이브러리 본체 (`game.project` 의 `[library] include_dirs = supabase` 로 공유). `require("supabase.client")`
- `tests/`: LuaJIT 유닛 테스트 (가짜 transport/codec 주입, Defold API 미사용)
- `example/`: 실서버 스모크 테스트 (부트스트랩 컬렉션). `game.project` `[supabase]` 값 + `example/setup.sql` 필요

## 규칙
- 라이브러리 코드는 Defold 전역(`http`, `json`)을 `client.lua` 의 기본 transport/codec 에서만 사용한다. 나머지는 순수 Lua 로 유지해 LuaJIT 단독 테스트가 가능해야 한다.
- 기능 추가 시 `tests/test_supabase.lua` 에 테스트를 추가하고, `README.md` 의 API 표와 Feature coverage 표를 갱신한다.
- 검증: `tools/verify.sh` (에디터 미실행 시 `--no-compile`).
