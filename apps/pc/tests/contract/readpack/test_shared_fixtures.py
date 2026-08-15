import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.packaging.infrastructure.validator import ReadpackValidator
from engirdle_pc.modules.packaging.public import InvalidReadpack


@pytest.mark.parametrize(
    "fixture_name",
    ["minimal.readpack", "mixed-markdown.readpack", "v10-legacy-list-quote.readpack"],
)
def test_pc_validator_accepts_shared_valid_readpack_fixtures(fixture_name: str) -> None:
    contracts = Settings().contracts_dir
    validator = ReadpackValidator(contracts)

    validator.validate(contracts / "readpack/v1/fixtures/valid" / fixture_name)


@pytest.mark.parametrize(
    "fixture_name",
    [
        "article-id-mismatch.readpack",
        "code-with-translation.readpack",
        "divider-with-sentences.readpack",
        "duplicate-cell-id.readpack",
        "duplicate-path.readpack",
        "empty-runs.readpack",
        "invalid-article-schema.readpack",
        "invalid-attribution-schema.readpack",
        "invalid-audio-range.readpack",
        "missing-file.readpack",
        "missing-translation.readpack",
        "no-narration.readpack",
        "oversized-entry.readpack",
        "path-traversal.readpack",
        "table-translation-shape.readpack",
        "unknown-capability.readpack",
        "unsupported-major.readpack",
        "v10-with-markdown-blocks.readpack",
        "wrong-hash.readpack",
    ],
)
def test_pc_validator_rejects_shared_invalid_readpack_fixtures(
    fixture_name: str,
) -> None:
    contracts = Settings().contracts_dir
    validator = ReadpackValidator(contracts)
    fixture = contracts / "readpack/v1/fixtures/invalid" / fixture_name

    with pytest.raises(InvalidReadpack):
        validator.validate(fixture)
