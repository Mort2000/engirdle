import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.publishing.infrastructure.validator import CatalogValidator
from engirdle_pc.modules.publishing.public import InvalidCatalog


def test_pc_validator_accepts_shared_valid_catalog_fixture() -> None:
    contracts = Settings().contracts_dir
    validator = CatalogValidator(contracts)

    validator.validate_file(contracts / "catalog/v1/fixtures/valid/minimal.json")


@pytest.mark.parametrize(
    "fixture_name",
    [
        "cross-origin-url.json",
        "duplicate-article.json",
        "duplicate-url.json",
        "unsafe-url.json",
        "unsupported-major.json",
    ],
)
def test_pc_validator_rejects_shared_invalid_catalog_fixtures(
    fixture_name: str,
) -> None:
    contracts = Settings().contracts_dir
    validator = CatalogValidator(contracts)
    fixture = contracts / "catalog/v1/fixtures/invalid" / fixture_name

    with pytest.raises(InvalidCatalog):
        validator.validate_file(fixture)
