PYTHON ?= python3
SIM ?= iverilog
DATAFLOW ?= os
RANDOM ?= 8
SEED ?= 20261117
STALLS ?= 1
STRIPS ?= 2
ARGS ?=
.PHONY: test quick regression model lut-check arithmetic array lint scope scope-compare scope-array scope-lint os-scope os-scope-lint
test:
	$(PYTHON) scripts/run.py --sim $(SIM) --dataflow $(DATAFLOW) --random $(RANDOM) --seed $(SEED) --stalls $(STALLS) $(ARGS)
quick:
	$(PYTHON) scripts/run.py --sim $(SIM) --dataflow $(DATAFLOW) --random 0 $(ARGS)
regression:
	$(PYTHON) scripts/run.py --sim $(SIM) --dataflow $(DATAFLOW) --random 64 --seed $(SEED) $(ARGS)
model:
	$(PYTHON) -m unittest discover -s tests -v
lut-check:
	$(PYTHON) scripts/gen_exp.py --check
arithmetic:
	$(PYTHON) scripts/run_arithmetic.py --sim $(SIM) $(ARGS)
array:
	$(PYTHON) scripts/run_array.py --sim $(SIM) --dataflow $(DATAFLOW) $(ARGS)
lint:
	$(PYTHON) scripts/lint.py --dataflow $(DATAFLOW) $(ARGS)
scope:
	$(PYTHON) scripts/run_scope.py --sim $(SIM) --strips $(STRIPS) $(ARGS)
scope-compare:
	$(PYTHON) scripts/run_scope.py --designs baseline stream scope os-scope --sim $(SIM) --strips $(STRIPS) $(ARGS)
scope-array:
	$(PYTHON) scripts/run_scope_array.py $(ARGS)
scope-lint:
	$(PYTHON) scripts/lint.py --dataflow scope --strips $(STRIPS) $(ARGS)
os-scope:
	$(PYTHON) scripts/run_scope.py --designs os-scope --sim $(SIM) $(ARGS)
os-scope-lint:
	$(PYTHON) scripts/lint.py --dataflow os-scope $(ARGS)
