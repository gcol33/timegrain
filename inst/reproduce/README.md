# Reproducing the Schrankogel grid

`schrankogel.R` runs the published grid from the deposit it was built on.

```
Rscript schrankogel.R <deposit_dir> <out_dir> [--name=value ...]
```

`<deposit_dir>` is the unpacked `data` directory of the Chytrý et al. deposit
(doi:10.5281/zenodo.17047026, CC BY 4.0). Four of its files are read: `spe_wide.csv`,
`logger_data.csv`, `seasons.csv` and `output_temperature_variables_scaled.csv`.

## Stages

| stage | what it does | writes |
|---|---|---|
| `contract` | the species filter, the fold map, the mask of scorable cells | `cells.csv` |
| `representation` | the record at all seven windows, with every bin count asserted | `representation.csv` |
| `baseline` | the aggregated-feature arms on the deposit's 188 variables | `baseline.csv` |
| `networks` | the encoders across the ladder | `networks_mean.csv`, `networks_extremeday.csv` |
| `contrasts` | every pair of arms, paired inside each cell both scored | `contrasts.csv` |
| `inflation` | what the reported levels are upper bounds on | `inflation.csv` |

The contract stage always runs, since everything downstream reads its response and its folds. The
default is every stage but `networks`.

## Options

- `--stages` comma-separated stage names.
- `--windows` which windows the network grid covers. Default `day,week,month,season,year`.
- `--learners` which encoders. Default `cnn`.
- `--baseline` which aggregated-feature arms: `elastic_net`, `stepwise`, or both. Default
  `elastic_net`. Forward selection over 188 columns is one fit per candidate per step per species
  per fold and takes many hours single-threaded.
- `--folds` a CSV of `logger_ID` and `fold`. Without it the script builds its own map, which is a
  different partition of the same design: `fold_map()` draws on R's random stream and the study's
  map came from `rsample`.
- `--epochs` epoch budget per network fit. Default 60, the budget the study used.

## What it asserts before fitting anything

The plot count, the species count after the contract filter, the rarest retained species, the cell
count, the reading count, the readings per plot, and the bin count of every window. A mismatch
stops the run rather than producing a number nobody can trace to an input.

Every stage reports the fold it is on as it goes, so a run measured in hours is distinguishable
from one that has hung.

## What it costs

Measured on one Windows processor, R 4.6.1:

| stage | time |
|---|---|
| contract | seconds |
| representation, all seven windows | about 2 minutes, 75 s of it reading the 1.2 GB CSV |
| baseline, elastic net, 101 species by 10 folds | tens of minutes |
| inflation, 2000 replicates at three planted levels | minutes |
| networks, coarse windows, one encoder | hours |
| networks, the hourly rung | wants a graphics processor, as it had in the study |

Nothing here caps the data. A stage runs over all 894 plots and all 101 species or it does not run.

## What has been checked against the paper

Verified on 2026-09-02 with the study's own fold map: 894 plots, 101 species, the rarest at 26
occurrences, 1003 of 1010 scorable cells (99.3 percent) with all 101 species keeping at least one
scorable fold, and bin counts of 26304, 2192, 1096, 157, 36, 13 and 3.
