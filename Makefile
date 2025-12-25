EXTENSION = polyvector
DATA = sql/polyvector--1.0.sql
MODULES =
PG_CONFIG = pg_config

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
