import Testing
@testable import Zone2UI

@Test @MainActor func tableRowsWithoutTheSeparator() {
    let md = """
    ## Вводные

    | параметр | значение |
    | --- | :-: |
    | Дата | **Вс 22.08.2027**, старт 08:00 |
    | Лимиты | Плавание 60 мин \\| общий 4:30 |

    - [ ] Шлем
    """
    let blocks = MarkdownText.blocks(md)
    #expect(blocks == [
        .heading(2, "Вводные"),
        .gap,
        .table([
            ["параметр", "значение"],
            ["Дата", "**Вс 22.08.2027**, старт 08:00"],
            ["Лимиты", "Плавание 60 мин | общий 4:30"],
        ]),
        .gap,
        .check(0, false, "Шлем"),
    ])
}

@Test @MainActor func tableCellsKeepOtherEscapes() {
    #expect(MarkdownText.tableCells("| a \\*b\\* | c |") == ["a \\*b\\*", "c"])
}
