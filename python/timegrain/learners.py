"""Learners: a fit and a predict pair, and the ones that ship.

Everything the package fits goes through the same pair, so a learner of your own sits beside the
ones here and needs no change to the ladder, the folds or the scoring. A learner that needs a
package says so and stops; there is no second path that runs without it.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from .representation import WindowMatrix

LEARNERS: dict[str, Callable[..., "Learner"]] = {}


@dataclass
class Learner:
    name: str
    fit: Callable
    predict: Callable
    needs: tuple[str, ...] = ()
    params: dict = field(default_factory=dict)

    def require(self) -> None:
        missing = [p for p in self.needs if importlib.util.find_spec(p) is None]
        if missing:
            raise ImportError(f"the {self.name} learner needs {' and '.join(missing)}. "
                              f"Install it with pip install {missing[0]}")


@dataclass
class Fit:
    learner: Learner
    model: object
    variables: tuple[str, ...]

    def predict(self, x: WindowMatrix) -> np.ndarray:
        p = np.asarray(self.learner.predict(self.model, x), dtype=np.float64)
        if p.shape[0] != x.values.shape[0]:
            raise ValueError(f"the learner returned {p.shape[0]} rows for "
                             f"{x.values.shape[0]} units")
        return p


def register_learner(name: str, constructor, overwrite: bool = False):
    """Make a learner available by name. The learners that ship are registered the same way."""
    if name in LEARNERS and not overwrite:
        raise ValueError(f'learner "{name}" is already registered')
    LEARNERS[name] = constructor
    return constructor


def get_learner(learner) -> Learner:
    if isinstance(learner, Learner):
        return learner
    if learner not in LEARNERS:
        raise KeyError(f'unknown learner "{learner}"; registered: {sorted(LEARNERS)}')
    return LEARNERS[learner]()


def fit_learner(learner, x: WindowMatrix, y, **kwargs) -> Fit:
    """Fit one learner at one grain."""
    learner = get_learner(learner)
    learner.require()
    y = y.align(x.units).check_presence_absence()
    model = learner.fit(x, y.values, **{**learner.params, **kwargs})
    return Fit(learner=learner, model=model, variables=y.variables)


def flatten(x: WindowMatrix) -> np.ndarray:
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

def _torch_learner(name, module_fn, arch, cfg) -> Learner:
    return Learner(name=name, needs=("torch",), params={},
                   fit=lambda x, y, **kw: _torch_fit(x, y, module_fn, arch, {**cfg, **kw}),
                   predict=_torch_predict)


def _torch_fit(x: WindowMatrix, y: np.ndarray, module_fn, arch, cfg):
    torch = _torch()
    device = cfg["device"] or ("cuda" if torch.cuda.is_available() else "cpu")

    m = np.transpose(x.values, (0, 2, 1))
    centre, scale = float(m.mean()), float(m.std()) + 1e-8
    m = (m - centre) / scale

    torch.manual_seed(cfg["seed"])
    rng = np.random.default_rng(cfg["seed"])
    n = m.shape[0]
    n_val = max(1, round(cfg["val_frac"] * n))
    val = rng.choice(n, size=n_val, replace=False) if cfg["val_frac"] > 0 and n - n_val >= 2 \
        else np.empty(0, dtype=int)
    fit_idx = np.setdiff1d(np.arange(n), val)

    xt = torch.tensor(m, dtype=torch.float32, device=device)
    yt = torch.tensor(y, dtype=torch.float32, device=device)
    pos = y[fit_idx].sum(axis=0)
    neg = len(fit_idx) - pos
    w = np.clip(np.where(pos > 0, neg / np.maximum(pos, 1), 1), 1, cfg["pos_weight_cap"])
    pw = torch.tensor(w, dtype=torch.float32, device=device)

    net = module_fn(in_ch=m.shape[1], in_len=m.shape[2], n_out=y.shape[1], **arch).to(device)
    opt = torch.optim.AdamW(net.parameters(), lr=cfg["lr"], weight_decay=cfg["weight_decay"])
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=cfg["epochs"])
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=pw)

    best_loss, best_state, bad = float("inf"), None, 0
    for _ in range(cfg["epochs"]):
        net.train()
        order = rng.permutation(fit_idx)
        for b in np.array_split(order, max(1, len(order) // cfg["batch_size"])):
            idx = torch.tensor(b, dtype=torch.long, device=device)
            opt.zero_grad()
            loss_fn(net(xt[idx]), yt[idx]).backward()
            opt.step()
        sched.step()
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
            if bad >= cfg["patience"]:
                break
    if best_state is not None:
        net.load_state_dict(best_state)
    net.eval().to(device)
    return dict(net=net, centre=centre, scale=scale, device=device, channels=x.stats,
                bins=x.values.shape[1], batch_size=cfg["batch_size"])


def _torch_predict(model, x: WindowMatrix) -> np.ndarray:
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


def _settings(epochs, batch_size, lr, weight_decay, val_frac, patience, pos_weight_cap, seed,
              device):
    return dict(epochs=epochs, batch_size=batch_size, lr=lr, weight_decay=weight_decay,
                val_frac=val_frac, patience=patience, pos_weight_cap=pos_weight_cap, seed=seed,
                device=device)


def mlp_learner(hidden=(512, 256), dropout=0.3, epochs=60, batch_size=64, lr=1e-3,
                weight_decay=1e-4, val_frac=0.15, patience=10, pos_weight_cap=50.0, seed=1,
                device=None) -> Learner:
    """Flattens the channels and builds in no temporal geometry."""
    return _torch_learner("mlp", _mlp_module, dict(hidden=tuple(hidden), dropout=dropout),
                          _settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                                    pos_weight_cap, seed, device))


def cnn_learner(channels=(16, 32, 64, 128), kernel=7, dropout=0.3, epochs=60, batch_size=32,
                lr=1e-3, weight_decay=1e-4, val_frac=0.15, patience=10, pos_weight_cap=50.0,
                seed=1, device=None) -> Learner:
    """Convolution, batch normalisation, activation and pooling, then global average pooling."""
    return _torch_learner("cnn", _cnn_module,
                          dict(channels=tuple(channels), kernel=kernel, dropout=dropout),
                          _settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                                    pos_weight_cap, seed, device))


def rescnn_learner(channels=(32, 64, 128, 256), blocks_per_stage=2, kernel=7,
                   dilations=(1, 2, 4, 8), dropout=0.3, epochs=60, batch_size=32, lr=1e-3,
                   weight_decay=1e-4, val_frac=0.15, patience=10, pos_weight_cap=50.0, seed=1,
                   device=None) -> Learner:
    """Dilated residual blocks with channel gates, pooling average and maximum together."""
    return _torch_learner("rescnn", _rescnn_module,
                          dict(channels=tuple(channels), blocks_per_stage=blocks_per_stage,
                               kernel=kernel, dilations=tuple(dilations), dropout=dropout),
                          _settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                                    pos_weight_cap, seed, device))


def elasticnet_learner(alpha=0.5, n_inner=5, squares=True, seed=1) -> Learner:
    """One penalised logistic regression per variable, over every bin-by-channel column and their
    squares, with the penalty chosen by an inner cross-validation on the fitting units."""

    def design(x):
        m = flatten(x)
        return np.hstack([m, m ** 2]) if squares else m

    def fit(x, y, **_):
        from sklearn.linear_model import LogisticRegressionCV
        m = design(x)
        models = []
        for j in range(y.shape[1]):
            yj = y[:, j]
            if len(np.unique(yj)) < 2:
                models.append(float(yj.mean()))
                continue
            models.append(LogisticRegressionCV(
                Cs=10, cv=n_inner, solver="saga", l1_ratios=[alpha],
                class_weight="balanced", max_iter=5000, random_state=seed).fit(m, yj))
        return dict(models=models, n_col=m.shape[1])

    def predict(model, x):
        m = design(x)
        if m.shape[1] != model["n_col"]:
            raise ValueError("the representation predicted on has different channels or bins "
                             "from the fitted one")
        return np.column_stack([
            np.full(m.shape[0], f) if isinstance(f, float) else f.predict_proba(m)[:, 1]
            for f in model["models"]])

    return Learner(name="elasticnet", fit=fit, predict=predict, needs=("sklearn",))


register_learner("mlp", mlp_learner)
register_learner("cnn", cnn_learner)
register_learner("rescnn", rescnn_learner)
register_learner("elasticnet", elasticnet_learner)
