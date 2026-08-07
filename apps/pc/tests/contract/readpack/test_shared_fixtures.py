import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.packaging.infrastructure.validator import ReadpackValidator
from engirdle_pc.modules.packaging.public import InvalidReadpack


def test_pc_validator_accepts_shared_valid_readpack_fixture() -> None:
    contracts = Settings().contracts_dir
    validator = ReadpackValidator(contracts)

    validator.validate(contracts / "readpack/v1/fixtures/valid/minimal.readpack")


@pytest.mark.parametrize(
    "fixture_name",
    [
        "article-id-mismatch.readpack",
        "duplicate-path.readpack",
        "invalid-article-schema.readpack",
        "invalid-attribution-schema.readpack",
        "invalid-audio-range.readpack",
        "missing-file.readpack",
        "missing-translation.readpack",
        "oversized-entry.readpack",
        "path-traversal.readpack",
        "unsupported-major.readpack",
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
