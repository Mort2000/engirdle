from __future__ import annotations

from engirdle_pc.modules.translation.application.ports import SentenceTranslation
from engirdle_pc.modules.translation.infrastructure.sqlalchemy_repository import (
    SqlAlchemyTranslationRepository,
)


def test_translation_save_with_empty_batch_is_a_no_op(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)

    store.save("job-1", (), "stub")  # must not raise (regression guard)

    assert store.list_for_job("job-1") == ()


def test_translation_save_and_list_round_trip(database, seed_build_job) -> None:
    seed_build_job()
    store = SqlAlchemyTranslationRepository(database)

    store.save(
        "job-1",
        (SentenceTranslation("s1", "你好"), SentenceTranslation("s2", "世界")),
        "stub",
    )

    listed = store.list_for_job("job-1")
    assert [item.sentence_id for item in listed] == ["s1", "s2"]
    assert listed[0].generated_text == "你好"
