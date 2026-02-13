# Hook Experiments

Scientific verification of Claude Code hooks.

## Structure

```
experiments/
├── hooks/
│   └── probe.sh         # Test hook script (logs everything)
├── logs/
│   └── YYYY-MM-DD_HHMMSS_<experiment>.log
├── observations/
│   └── YYYY-MM-DD_<experiment>.md   # Human notes + findings
└── README.md
```

## Workflow

1. **Hypothesis**: What do we expect to happen?
2. **Setup**: Configure hooks, prepare environment
3. **Execute**: Run the test scenario
4. **Observe**: Check logs, note actual behavior
5. **Record**: Document findings in observations/

## Running Experiments

```bash
# View live log
tail -f logs/current.log

# Clear log before new experiment
./scripts/new-experiment.sh "experiment-name"
```
