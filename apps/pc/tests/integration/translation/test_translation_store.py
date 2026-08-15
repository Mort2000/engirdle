from __future__ import annotations

import pytest

from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    SentenceTranslation,
    SentenceUnitTranslation,
    TableShapeMismatch,
    TableTranslatedCell,
    TableUnitTranslation,
    verify_edited_table_shape,
)
from engirdle_pc.modules.translation.infrastructure.sqlalchemy_repository import (
    SqlAlchemyTranslationRepository,
)


def _sentence_unit(block_id: str, texts: tuple[tuple[str, str], ...]) -> AcceptedTranslation:
    return AcceptedTranslation(
        translation=SentenceUnitTranslation(
            block_id=block_id,
            translations=tuple(
                SentenceTranslation(sentence_id=sentence_id, text_zh=text_zh)
                for sentence_id, text_zh in texts
            ),
        ),
        request_id="req-1",
    )


def _table_unit(block_id: str, cells: tuple[tuple[str, str], ...]) -> AcceptedTranslation:
    return AcceptedTranslation(
        translation=TableUnitTranslation(
            block_id=block_id,
            cells=tuple(
                TableTranslatedCell(cell_id=cell_id, text_zh=text_zh)
                for cell_id, text_zh in cells
            ),
        ),
        request_id="req-2",
    )


def test_translation_save_with_empty_batch_is_a_no_op(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)

    store.save("job-1", (), "stub")  # must not raise (regression guard)

    assert store.list_for_job("job-1") == ()


def test_sentence_unit_save_and_list_round_trip(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)

    store.save(
        "job-1",
        (_sentence_unit("block-1", (("s1", "你好"), ("s2", "世界"))),),
        "stub",
    )

    listed = store.list_for_job("job-1")
    assert len(listed) == 1
    reviewed = listed[0]
    assert reviewed.unit_id == "block-1"
    assert reviewed.unit_kind.value == "sentence"
    assert reviewed.adapter_name == "stub"
    assert [item.sentence_id for item in reviewed.generated.translations] == ["s1", "s2"]
    assert [item.text_zh for item in reviewed.generated.translations] == ["你好", "世界"]
    assert reviewed.edited is None
    assert reviewed.published.translations == reviewed.generated.translations


def test_table_unit_save_and_list_round_trip(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)

    store.save(
        "job-1",
        (_table_unit("block-9", (("cell-1", "甲"), ("cell-2", "乙"))),),
        "stub",
    )

    listed = store.list_for_job("job-1")
    assert len(listed) == 1
    reviewed = listed[0]
    assert reviewed.unit_id == "block-9"
    assert reviewed.unit_kind.value == "table"
    assert [(cell.cell_id, cell.text_zh) for cell in reviewed.generated.cells] == [
        ("cell-1", "甲"),
        ("cell-2", "乙"),
    ]


def test_edit_sentence_rewrites_only_the_targetted_entry(
    database, seed_build_job
) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)
    store.save(
        "job-1",
        (_sentence_unit("block-1", (("s1", "你好"), ("s2", "世界"))),),
        "stub",
    )

    store.edit_sentence("job-1", "s2", "人间")

    reviewed = store.list_for_job("job-1")[0]
    assert reviewed.edited is not None
    published = {item.sentence_id: item.text_zh for item in reviewed.published.translations}
    assert published == {"s1": "你好", "s2": "人间"}


def test_edit_sentence_for_unknown_sentence_raises_key_error(
    database, seed_build_job
) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)
    store.save(
        "job-1",
        (_sentence_unit("block-1", (("s1", "你好"),)),),
        "stub",
    )

    with pytest.raises(KeyError):
        store.edit_sentence("job-1", "missing", "无所谓")


def test_edit_table_replaces_the_whole_edited_payload(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)
    store.save(
        "job-1",
        (_table_unit("block-9", (("cell-1", "甲"), ("cell-2", "乙"))),),
        "stub",
    )

    store.edit_table(
        "job-1",
        "block-9",
        TableUnitTranslation(
            block_id="block-9",
            cells=(
                TableTranslatedCell(cell_id="cell-1", text_zh="甲-改"),
                TableTranslatedCell(cell_id="cell-2", text_zh="乙-改"),
            ),
        ),
    )

    reviewed = store.list_for_job("job-1")[0]
    assert reviewed.edited is not None
    assert [(cell.cell_id, cell.text_zh) for cell in reviewed.edited.cells] == [
        ("cell-1", "甲-改"),
        ("cell-2", "乙-改"),
    ]


def test_edit_table_for_unknown_block_raises_key_error(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)
    store.save(
        "job-1",
        (_table_unit("block-9", (("cell-1", "甲"),)),),
        "stub",
    )

    with pytest.raises(KeyError):
        store.edit_table(
            "job-1",
            "missing-block",
            TableUnitTranslation(
                block_id="missing-block",
                cells=(TableTranslatedCell(cell_id="cell-1", text_zh="甲"),),
            ),
        )


def test_verify_edited_table_shape_rejects_identity_changes() -> None:
    original = TableUnitTranslation(
        block_id="block-9",
        cells=(
            TableTranslatedCell(cell_id="cell-1", text_zh="甲"),
            TableTranslatedCell(cell_id="cell-2", text_zh="乙"),
        ),
    )

    verify_edited_table_shape(
        original,
        TableUnitTranslation(
            block_id="block-9",
            cells=(
                TableTranslatedCell(cell_id="cell-1", text_zh="甲-改"),
                TableTranslatedCell(cell_id="cell-2", text_zh="乙-改"),
            ),
        ),
    )

    with pytest.raises(TableShapeMismatch):
        verify_edited_table_shape(
            original,
            TableUnitTranslation(
                block_id="block-9",
                cells=(TableTranslatedCell(cell_id="cell-1", text_zh="甲"),),
            ),
        )
    with pytest.raises(TableShapeMismatch):
        verify_edited_table_shape(
            original,
            TableUnitTranslation(
                block_id="other-block",
                cells=tuple(original.cells),
            ),
        )
