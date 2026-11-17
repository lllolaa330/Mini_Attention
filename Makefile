PYTHON ?= python3
SIM ?= iverilog
RANDOM ?= 8
SEED ?= 20261117
STALLS ?= 1
ARGS ?=
.PHONY: test quick regression model lut-check arithmetic array lint
test:
	$(PYTHON) scripts/run.py --sim $(SIM) --random $(RANDOM) --seed $(SEED) --stalls $(STALLS) $(ARGS)
quick:
	$(PYTHON) scripts/run.py --sim $(SIM) --random 0 $(ARGS)
regression:
	$(PYTHON) scripts/run.py --sim $(SIM) --random 64 --seed $(SEED) $(ARGS)
model:
	$(PYTHON) -m unittest discover -s tests -v
lut-check:
	$(PYTHON) scripts/gen_exp.py --check
arithmetic:
	$(PYTHON) scripts/run_arithmetic.py --sim $(SIM) $(ARGS)
array:
	$(PYTHON) scripts/run_array.py --sim $(SIM) $(ARGS)
lint:
	$(PYTHON) scripts/lint.py $(ARGS)
