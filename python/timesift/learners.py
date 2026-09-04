"""Learners: a fit and a predict pair, and the ones that ship.

Everything the package fits goes through the same pair, so a learner of your own sits beside the
ones here and needs no change to the ladder, the folds or the scoring. A learner that needs a
package says so and stops; there is no second path that runs without it.

A learner also declares what it can be handed and how it covers several responses, so the layer
above can pair it with a representation and assemble its predictions without asking what kind of
model it is.
"""

from __future__ import annotations

import importlib.util
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from .control import CONTROL_SETTINGS, as_control, check_settings
from .registry import get_learner
from .representation import TimesiftMatrix

__all__ = ["Fit", "Learner", "READS", "MULTI", "cnn", "elasticnet", "fit_learner", "flatten",
           "mlp", "rescnn", "forest", "stepwise"]

READS = ("tabular", "sequence")
MULTI = ("joint", "separate")


@dataclass
class Learner:
    """A name, a fit and a predict, what has to be installed for them to run, and what the learner
    reads.

    The one interface every arm goes through, the ones that ship and a pair of your own alike.
    ``data`` pins the learner to one representation, or is ``None`` to run it across every
    representation offered. ``reads`` is whether it takes a tabular block or an ordered sequence of
    bins, and ``multi`` is whether one fitted model covers every response or one is fitted per
    response and the matrix assembled from them.
    """

    name: str
    fit: Callable
    predict: Callable
    needs: tuple[str, ...] = ()
    params: dict = field(default_factory=dict)
    data: object = None
    reads: str = "tabular"
    multi: str = "separate"

    def __post_init__(self):
        if self.reads not in READS:
            raise ValueError(f"`reads` is one of {', '.join(READS)}, got {self.reads!r}")
        if self.multi not in MULTI:
            raise ValueError(f"`multi` is one of {', '.join(MULTI)}, got {self.multi!r}")

    def require(self) -> None:
        """Error, naming the install, unless what the learner needs is importable."""
        missing = [p for p in self.needs if importlib.util.find_spec(p) is None]
        if missing:
            raise ImportError(f"the {self.name} learner needs {' and '.join(missing)}. "
                              f"Install it with pip install {missing[0]}")


@dataclass
class Fit:
    """A fitted learner and the variables it was fitted on."""

    learner: Learner
    model: object
    variables: tuple[str, ...]
    response: str = "presence_absence"

    def predict(self, x: TimesiftMatrix) -> np.ndarray:
        """Predictions for a representation, as a `[unit, variable]` matrix."""
        p = np.asarray(self.learner.predict(self.model, x), dtype=np.float64)
        if p.shape[0] != x.values.shape[0]:
            raise ValueError(f"the learner returned {p.shape[0]} rows for "
                             f"{x.values.shape[0]} units")
        return p


def fit_learner(learner, x: TimesiftMatrix, y, response: str = "presence_absence",
                **kwargs) -> Fit:
    """Fit one learner at one grain, under one registered response head."""
    from .registry import RESPONSES
    from .response import as_response
    learner = get_learner(learner)
    learner.require()
    y = RESPONSES.get(response)["prepare"](as_response(y)).align(x.units)
    model = learner.fit(x, y.values, **{**learner.params, **kwargs})
    return Fit(learner=learner, model=model, variables=y.variables, response=response)


def flatten(x: TimesiftMatrix) -> np.ndarray:
    """``[unit, bin, channel]`` to ``[unit, bin * channel]`` in the array's own order."""
    n_u = x.values.shape[0]
    return x.values.reshape(n_u, -1, order="F")


# ---- the encoders ----------------------------------------------------------------------------

def _torch():
    try:
        import torch  # noqa: F401
    except ImportError as e:  # pragma: no cover - the message is the point
        raise ImportError("this learner needs torch. Install it with pip install torch") from e
    return importlib.import_module("torch")


class _LenSafePool:
    """Pools while there is something to halve, and is the identity once there is not, so the same
    stack runs at every grain of a ladder including one bin per year."""

    def __new__(cls, kernel: int = 2):
        torch = _torch()
        nn = torch.nn

        class Pool(nn.Module):
            def __init__(self):
                super().__init__()
                self.kernel = kernel
                self.pool = nn.MaxPool1d(kernel)

            def forward(self, z):
                return z if z.shape[-1] < self.kernel else self.pool(z)

        return Pool()


def _mlp_module(in_ch, in_len, n_out, hidden, dropout):
    nn = _torch().nn
    layers = [nn.Flatten()]
    prev = in_ch * in_len
    for k, h in enumerate(hidden):
        layers += [nn.Linear(prev, h), nn.ReLU()]
        if k < len(hidden) - 1:
            layers.append(nn.Dropout(dropout))
        prev = h
    layers += [nn.Dropout(dropout), nn.Linear(prev, n_out)]
    return nn.Sequential(*layers)


def _cnn_module(in_ch, in_len, n_out, channels, kernel, dropout):
    nn = _torch().nn
    layers, prev = [], in_ch
    for c in channels:
        layers += [nn.Conv1d(prev, c, kernel, padding=kernel // 2), nn.BatchNorm1d(c),
                   nn.ReLU(), _LenSafePool()]
        prev = c
    layers += [nn.AdaptiveAvgPool1d(1), nn.Flatten(), nn.Dropout(dropout),
               nn.Linear(prev, n_out)]
    return nn.Sequential(*layers)


def _rescnn_module(in_ch, in_len, n_out, channels, blocks_per_stage, kernel, dilations, dropout):
    torch = _torch()
    nn = torch.nn

    class SE(nn.Module):
        def __init__(self, c, r=8):
            super().__init__()
            h = max(c // r, 4)
            self.fc = nn.Sequential(nn.Linear(c, h), nn.GELU(), nn.Linear(h, c), nn.Sigmoid())

        def forward(self, z):
            return z * self.fc(z.mean(dim=-1)).unsqueeze(-1)

    class ResBlock(nn.Module):
        def __init__(self, c, kernel, dilation, dropout):
            super().__init__()
            pad = (kernel // 2) * dilation
            self.conv = nn.Sequential(
                nn.Conv1d(c, c, kernel, padding=pad, dilation=dilation), nn.BatchNorm1d(c),
                nn.GELU(), nn.Dropout(dropout),
                nn.Conv1d(c, c, kernel, padding=pad, dilation=dilation), nn.BatchNorm1d(c))
            self.se = SE(c)

        def forward(self, z):
            return nn.functional.gelu(z + self.se(self.conv(z)))

    class ResCNN(nn.Module):
        def __init__(self):
            super().__init__()
            self.stem = nn.Sequential(
                nn.Conv1d(in_ch, channels[0], kernel, padding=kernel // 2),
                nn.BatchNorm1d(channels[0]), nn.GELU())
            layers, prev = [], channels[0]
            for si, c in enumerate(channels):
                if c != prev:
                    layers += [nn.Conv1d(prev, c, 1), nn.BatchNorm1d(c), nn.GELU()]
                d = dilations[si % len(dilations)]
                layers += [ResBlock(c, kernel, d, dropout) for _ in range(blocks_per_stage)]
                layers.append(_LenSafePool())
                prev = c
            self.features = nn.Sequential(*layers)
            self.head = nn.Sequential(nn.Dropout(dropout), nn.Linear(prev * 2, n_out))

        def forward(self, z):
            h = self.features(self.stem(z))
            return self.head(torch.cat([h.mean(dim=-1), h.amax(dim=-1)], dim=1))

    return ResCNN()


# ---- the training recipe ---------------------------------------------------------------------

# One learner factory for every encoder: the architecture is a module constructor and nothing
# else, so the training recipe, the standardiser, the class weighting and the early stopping have
# one definition and cannot drift between architectures. Architecture reaches the module builder
# and everything else reaches the control, so a setting given at fit time is applied to whichever
# of the two it belongs to.
def _torch_learner(name, module_fn, arch, given, data, reads) -> Learner:
    settings = check_settings(given)

    def fit(x, y, control=None, **passed):
        unknown = set(passed) - set(arch) - set(CONTROL_SETTINGS)
        if unknown:
            raise TypeError(f"the {name} learner has no setting called "
                            f"{', '.join(sorted(unknown))}")
        return _torch_fit(x, y, module_fn,
                          {**arch, **{k: v for k, v in passed.items() if k in arch}},
                          as_control(control).override(
                              {k: v for k, v in passed.items() if k in CONTROL_SETTINGS}))

    return Learner(name=name, needs=("torch",), params={**arch, **settings}, fit=fit,
                   predict=_torch_predict, data=data, reads=reads, multi="joint")


def _resolve_device(name):
    torch = _torch()
    if name in (None, "auto"):
        return "cuda" if torch.cuda.is_available() else "cpu"
    return name


def _torch_fit(x: TimesiftMatrix, y: np.ndarray, module_fn, arch, cfg):
    torch = _torch()
    device = _resolve_device(cfg.device)

    m = np.transpose(x.values, (0, 2, 1))
    centre, scale = float(m.mean()), float(m.std()) + 1e-8
    m = (m - centre) / scale

    torch.manual_seed(cfg.seed)
    rng = np.random.default_rng(cfg.seed)
    n = m.shape[0]
    n_val = max(1, round(cfg.val_frac * n))
    val = rng.choice(n, size=n_val, replace=False) if cfg.val_frac > 0 and n - n_val >= 2 \
        else np.empty(0, dtype=int)
    fit_idx = np.setdiff1d(np.arange(n), val)

    xt = torch.tensor(m, dtype=torch.float32, device=device)
    yt = torch.tensor(y, dtype=torch.float32, device=device)
    pos = y[fit_idx].sum(axis=0)
    neg = len(fit_idx) - pos
    w = np.clip(np.where(pos > 0, neg / np.maximum(pos, 1), 1), 1, cfg.pos_weight_cap)
    pw = torch.tensor(w, dtype=torch.float32, device=device)

    net = module_fn(in_ch=m.shape[1], in_len=m.shape[2], n_out=y.shape[1], **arch).to(device)
    opt = torch.optim.AdamW(net.parameters(), lr=cfg.learning_rate,
                            weight_decay=cfg.weight_decay)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=cfg.epochs)
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=pw)

    best_loss, best_state, bad = float("inf"), None, 0
    # The schedule anneals until the averaging begins and is then held flat, and the epochs it
    # averages over neither validate nor stop early: averaging the tail is a way of walking the
    # flat basin rather than of picking a single epoch out of it.
    swa_from = max(1, int(cfg.swa_start * cfg.epochs)) if cfg.swa else cfg.epochs + 1
    average, n_average = None, 0
    for epoch in range(1, cfg.epochs + 1):
        net.train()
        order = rng.permutation(fit_idx)
        for b in np.array_split(order, max(1, len(order) // cfg.batch_size)):
            idx = torch.tensor(b, dtype=torch.long, device=device)
            opt.zero_grad()
            loss_fn(net(xt[idx]), yt[idx]).backward()
            opt.step()
        if epoch < swa_from:
            sched.step()
        else:
            average, n_average = _accumulate(net, average, n_average)
            continue
        if not len(val):
            continue
        net.eval()
        with torch.no_grad():
            vloss = float(loss_fn(net(xt[torch.tensor(val, dtype=torch.long, device=device)]),
                                  yt[torch.tensor(val, dtype=torch.long, device=device)]))
        if vloss < best_loss - 1e-4:
            best_loss, bad = vloss, 0
            best_state = {k: v.detach().cpu().clone() for k, v in net.state_dict().items()}
        else:
            bad += 1
            if bad >= cfg.early_stopping:
                break
    if n_average:
        net.load_state_dict(average)
        net.to(device)
        _refresh_batchnorm(net, xt, fit_idx, cfg.batch_size, device)
    elif best_state is not None:
        net.load_state_dict(best_state)
    net.eval().to(device)
    return dict(net=net, centre=centre, scale=scale, device=device, channels=x.stats,
                bins=x.values.shape[1], batch_size=cfg.batch_size)


def _accumulate(net, average, n):
    """A running mean of the weights. Only the floating-point entries are weights: a
    batch-normalisation module also carries an integer count of the batches it has seen, and a
    running mean of that is not a number."""
    state = {k: v.detach().cpu().clone() for k, v in net.state_dict().items()}
    if not n:
        return state, 1
    n += 1
    for k, v in state.items():
        if v.dtype.is_floating_point:
            average[k] = average[k] + (v - average[k]) / n
        else:
            average[k] = v
    return average, n


def _refresh_batchnorm(net, xt, fit_idx, batch_size, device):
    """Batch normalisation carries running statistics that belong to the weights that produced
    them, so an average of weights needs its own pass over the fitting units before it predicts
    anything."""
    torch = _torch()
    net.train()
    with torch.no_grad():
        for b in np.array_split(fit_idx, max(1, len(fit_idx) // batch_size)):
            net(xt[torch.tensor(b, dtype=torch.long, device=device)])
    return net


def _torch_predict(model, x: TimesiftMatrix) -> np.ndarray:
    torch = _torch()
    if tuple(x.stats) != tuple(model["channels"]) or x.values.shape[1] != model["bins"]:
        raise ValueError("the representation predicted on has different channels or bins from "
                         "the fitted one")
    m = (np.transpose(x.values, (0, 2, 1)) - model["centre"]) / model["scale"]
    xt = torch.tensor(m, dtype=torch.float32, device=model["device"])
    out = []
    with torch.no_grad():
        for b in np.array_split(np.arange(m.shape[0]),
                                max(1, m.shape[0] // model["batch_size"])):
            idx = torch.tensor(b, dtype=torch.long, device=model["device"])
            out.append(torch.sigmoid(model["net"](xt[idx])).cpu().numpy())
    return np.concatenate(out, axis=0)


def mlp(data=None, hidden=(512, 256), dropout=0.3, **settings) -> Learner:
    """Flattens the channels and builds in no temporal geometry.

    ``hidden`` and ``dropout`` are the architecture; anything else named is a training setting
    applied on top of the ``train_control()`` the learner is fitted under.
    """
    return _torch_learner("mlp", _mlp_module, dict(hidden=tuple(hidden), dropout=dropout),
                          settings, data=data, reads="tabular")


def cnn(data=None, channels=(16, 32, 64, 128), kernel=7, dropout=0.3, **settings) -> Learner:
    """Convolution, batch normalisation, activation and pooling, then global average pooling."""
    return _torch_learner("cnn", _cnn_module,
                          dict(channels=tuple(channels), kernel=kernel, dropout=dropout),
                          settings, data=data, reads="sequence")


def rescnn(data=None, channels=(32, 64, 128, 256), blocks_per_stage=2, kernel=7,
           dilations=(1, 2, 4, 8), dropout=0.3, **settings) -> Learner:
    """Dilated residual blocks with channel gates, pooling average and maximum together."""
    return _torch_learner("rescnn", _rescnn_module,
                          dict(channels=tuple(channels), blocks_per_stage=blocks_per_stage,
                               kernel=kernel, dilations=tuple(dilations), dropout=dropout),
                          settings, data=data, reads="sequence")


# ---- one model per response ------------------------------------------------------------------

# The learners that cover the responses one at a time share how a response is fitted and how the
# matrix is put back together, so the difference between them is the model and nothing else. A
# response with one outcome among the fitting units has no model to fit and is predicted its own
# share, which is the level a fitted model would collapse to.
def _fit_columns(m: np.ndarray, y: np.ndarray, make) -> list:
    out = []
    for j in range(y.shape[1]):
        yj = y[:, j]
        out.append(float(yj.mean()) if len(np.unique(yj)) < 2 else make(m, yj))
    return out


def _same_columns(m: np.ndarray, n_col: int) -> np.ndarray:
    if m.shape[1] != n_col:
        raise ValueError("the representation predicted on has different channels or bins "
                         "from the fitted one")
    return m


def _predict_columns(models: list, m: np.ndarray, n_col: int) -> np.ndarray:
    _same_columns(m, n_col)
    return np.column_stack([
        np.full(m.shape[0], f) if isinstance(f, float) else f.predict_proba(m)[:, 1]
        for f in models])


def _design(x: TimesiftMatrix, squares: bool) -> np.ndarray:
    m = flatten(x)
    return np.hstack([m, m ** 2]) if squares else m


def elasticnet(data=None, alpha=0.5, n_inner=5, squares=True, weight_positives=True,
               seed=1) -> Learner:
    """One penalised logistic regression per variable, over every bin-by-channel column and, by
    default, their squares, with the penalty chosen by an inner cross-validation on the fitting
    units.

    There is no discrete selection step: the penalty path uses every column and shrinks, and
    nothing about the model is decided outside the fold it is fitted in.
    """
    return Learner(name="elasticnet", fit=_elasticnet_fit, predict=_elasticnet_predict,
                   needs=("sklearn",), data=data, reads="tabular", multi="separate",
                   params=dict(alpha=alpha, n_inner=n_inner, squares=squares,
                               weight_positives=weight_positives, seed=seed))


def _elasticnet_fit(x, y, alpha, n_inner, squares, weight_positives, seed, **_):
    from sklearn.linear_model import LogisticRegressionCV
    m = _design(x, squares)

    def make(design, yj):
        return LogisticRegressionCV(
            Cs=10, cv=n_inner, solver="saga", l1_ratios=[alpha],
            class_weight="balanced" if weight_positives else None,
            max_iter=5000, random_state=seed).fit(design, yj)

    return dict(models=_fit_columns(m, y, make), squares=squares, n_col=m.shape[1])


def _elasticnet_predict(model, x):
    return _predict_columns(model["models"], _design(x, model["squares"]), model["n_col"])


def forest(data=None, trees=500, mtry=None, min_node=1, seed=1) -> Learner:
    """One random forest per variable, over every bin-by-channel column.

    ``mtry`` is how many columns are offered at a split, defaulting to the square root of how many
    there are, and ``min_node`` is the smallest leaf a split may produce. The forest reads the
    columns one at a time and carries no order between them, so it is the arm that asks what the
    features hold once nothing about the record's shape is available to the model.
    """
    return Learner(name="forest", fit=_rf_fit, predict=_rf_predict, needs=("sklearn",),
                   data=data, reads="tabular", multi="separate",
                   params=dict(trees=trees, mtry=mtry, min_node=min_node, seed=seed))


def _rf_fit(x, y, trees, mtry, min_node, seed, **_):
    from sklearn.ensemble import RandomForestClassifier
    m = flatten(x)

    def make(design, yj):
        return RandomForestClassifier(
            n_estimators=trees, max_features="sqrt" if mtry is None else mtry,
            min_samples_leaf=min_node, random_state=seed, n_jobs=-1).fit(design, yj)

    return dict(models=_fit_columns(m, y, make), n_col=m.shape[1])


def _rf_predict(model, x):
    return _predict_columns(model["models"], flatten(x), model["n_col"])


def stepwise(data=None, max_terms=3, degree=2) -> Learner:
    """One logistic regression per variable, its predictors chosen by forward selection over every
    bin-by-channel column, admitting a column while it lowers Akaike's criterion and stopping at a
    fixed budget.

    Each candidate enters as an orthogonal polynomial, so a term can be non-monotone in the reading
    the way a niche optimum is. Selection happens inside whichever units the learner is handed, so
    under :func:`grain_ladder` it is redone in every fold. Reported beside a penalised fit it also
    prices discrete selection: choosing a handful of columns out of hundreds is high variance, and
    that variance is a cost of the selector rather than of the features.
    """
    return Learner(name="stepwise", fit=_stepwise_fit, predict=_stepwise_predict,
                   data=data, reads="tabular", multi="separate",
                   params=dict(max_terms=max_terms, degree=degree))


def _stepwise_fit(x, y, max_terms, degree, **_):
    m = flatten(x)
    return dict(models=[_forward_aic(m, y[:, j], max_terms, degree) for j in range(y.shape[1])],
                n_col=m.shape[1], degree=degree)


def _stepwise_predict(model, x):
    m = _same_columns(flatten(x), model["n_col"])
    return np.column_stack([_predict_forward(f, m) for f in model["models"]])


# Forward selection by Akaike's criterion, one column admitted at a time. The polynomial basis is
# stored with the fit rather than rebuilt, because an orthogonal basis refitted on new units is a
# different basis.
def _forward_aic(m: np.ndarray, y: np.ndarray, max_terms: int, degree: int) -> dict:
    if len(np.unique(y)) < 2:
        return dict(constant=float(y.mean()))
    chosen: list[int] = []
    bases: list[dict] = []
    current = None
    best_aic = _logistic(np.empty((len(y), 0)), y)["aic"]
    while len(chosen) < max_terms:
        offered = []
        for j in range(m.shape[1]):
            if j in chosen:
                continue
            basis = _poly_basis(m[:, j], degree)
            design = np.hstack([b["values"] for b in bases] + [basis["values"]])
            fit = _logistic(design, y)
            if fit is not None and np.isfinite(fit["aic"]):
                offered.append((fit["aic"], j, fit, basis))
        if not offered:
            break
        _, j, fit, basis = min(offered, key=lambda o: (o[0], o[1]))
        if fit["aic"] >= best_aic:
            break
        best_aic, current = fit["aic"], fit
        chosen.append(j)
        bases.append(basis)
    if not chosen:
        return dict(constant=float(y.mean()))
    return dict(columns=chosen, bases=bases, fit=current)


def _predict_forward(f: dict, m: np.ndarray) -> np.ndarray:
    if "constant" in f:
        return np.full(m.shape[0], f["constant"])
    design = np.hstack([_apply_basis(b, m[:, j]) for j, b in zip(f["columns"], f["bases"])])
    eta = np.column_stack([np.ones(m.shape[0]), design]) @ f["fit"]["beta"]
    return 1.0 / (1.0 + np.exp(-eta))


def _logistic(design: np.ndarray, y: np.ndarray, max_iter: int = 25):
    """One logistic regression by iteratively reweighted least squares, and its criterion.

    A candidate whose fit separates the response, or does not settle, is refused rather than
    returned: those are the two states the criterion cannot be read off, and admitting one would
    let the selector prefer a column for having no answer. It is where R's forward pass discards a
    candidate its own fitter warned about.
    """
    x = np.column_stack([np.ones(len(y)), design]) if design.shape[1] else np.ones((len(y), 1))
    share = float(np.mean(y))
    beta = np.zeros(x.shape[1])
    beta[0] = np.log(share / (1.0 - share))
    deviance = np.inf
    for _ in range(max_iter):
        mu = _mu(x, beta)
        if mu is None:
            return None
        w = mu * (1.0 - mu)
        z = x @ beta + (y - mu) / w
        try:
            beta = np.linalg.solve((x * w[:, None]).T @ x, (x * w[:, None]).T @ z)
        except np.linalg.LinAlgError:
            return None
        if not np.all(np.isfinite(beta)):
            return None
        mu = _mu(x, beta)
        if mu is None:
            return None
        new = -2.0 * float(np.sum(y * np.log(mu) + (1 - y) * np.log1p(-mu)))
        if abs(new - deviance) / (abs(new) + 0.1) < 1e-8:
            return dict(beta=beta, deviance=new, aic=new + 2 * x.shape[1])
        deviance = new
    return None


def _mu(x: np.ndarray, beta: np.ndarray):
    """The fitted probabilities, or nothing where one of them has reached zero or one."""
    mu = 1.0 / (1.0 + np.exp(-(x @ beta)))
    return None if np.any(mu < 1e-8) or np.any(mu > 1 - 1e-8) else mu


# An orthogonal polynomial basis by the three-term recurrence, kept with the coefficients it was
# fitted beside so that new units are mapped through the same basis rather than through one
# re-derived from themselves. It is the basis R's poly() builds, by the same recurrence.
def _poly_basis(v: np.ndarray, degree: int) -> dict:
    degree = min(degree, max(1, len(np.unique(v)) - 1))
    powers = [np.ones(len(v))]
    norm2 = [float(len(v))]
    alpha = []
    for k in range(1, degree + 1):
        alpha.append(float(np.sum(v * powers[k - 1] ** 2) / norm2[k - 1]))
        if k == 1:
            nxt = (v - alpha[0]) * powers[0]
        else:
            nxt = (v - alpha[k - 1]) * powers[k - 1] - (norm2[k - 1] / norm2[k - 2]) * powers[k - 2]
        powers.append(nxt)
        norm2.append(float(np.sum(nxt ** 2)))
    basis = dict(degree=degree, alpha=alpha, norm2=norm2)
    basis["values"] = _apply_basis(basis, v)
    return basis


def _apply_basis(basis: dict, v: np.ndarray) -> np.ndarray:
    alpha, norm2, degree = basis["alpha"], basis["norm2"], basis["degree"]
    powers = [np.ones(len(v))]
    for k in range(1, degree + 1):
        if k == 1:
            powers.append((v - alpha[0]) * powers[0])
        else:
            powers.append((v - alpha[k - 1]) * powers[k - 1]
                          - (norm2[k - 1] / norm2[k - 2]) * powers[k - 2])
    return np.column_stack([powers[k] / np.sqrt(norm2[k]) for k in range(1, degree + 1)])
