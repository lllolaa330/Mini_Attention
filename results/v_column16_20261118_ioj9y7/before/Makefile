PYTHON ?= python3
SIM ?= iverilog
DATAFLOW ?= os
RANDOM ?= 8
SEED ?= 20261117
STALLS ?= 1
ARGS ?=
.PHONY: test quick regression model lut-check arithmetic array lint
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
