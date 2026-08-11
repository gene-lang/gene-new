"""A small, from-scratch, decoder-only Transformer -- deliberately the *same*
architecture class for both study arms (docs/proposals/
reversible-ai-native-program-format.md, "Model-training study": "The two
arms use the same backbone capacity, optimizer, training-example pool,
total training-FLOP budget, maximum context positions, and evaluation
tasks. Their input/output heads differ only where the modality requires
it."). The only thing that differs between the native-unit run and the
byte-control run is `vocab_size` (units_dataset.py's UnitVocab.size vs
ByteVocab.size) -- everything else in `ModelConfig` must be passed
identically to both, which train.py enforces by construction (one config,
one `--vocab-size` override point).

This is a plain pre-norm GPT-style block: nothing modality-specific lives
here on purpose, since the whole point of the study is to isolate the input
representation as the only variable.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class ModelConfig:
    vocab_size: int
    context_len: int = 1024
    d_model: int = 256
    n_layers: int = 6
    n_heads: int = 4
    d_ff: int = 1024
    dropout: float = 0.1


class CausalSelfAttention(nn.Module):
    def __init__(self, cfg: ModelConfig):
        super().__init__()
        assert cfg.d_model % cfg.n_heads == 0
        self.n_heads = cfg.n_heads
        self.head_dim = cfg.d_model // cfg.n_heads
        self.qkv = nn.Linear(cfg.d_model, 3 * cfg.d_model)
        self.proj = nn.Linear(cfg.d_model, cfg.d_model)
        self.dropout = cfg.dropout

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        b, t, c = x.shape
        qkv = self.qkv(x).view(b, t, 3, self.n_heads, self.head_dim).permute(2, 0, 3, 1, 4)
        q, k, v = qkv[0], qkv[1], qkv[2]
        out = F.scaled_dot_product_attention(
            q, k, v, is_causal=True, dropout_p=self.dropout if self.training else 0.0)
        out = out.transpose(1, 2).contiguous().view(b, t, c)
        return self.proj(out)


class Block(nn.Module):
    def __init__(self, cfg: ModelConfig):
        super().__init__()
        self.ln1 = nn.LayerNorm(cfg.d_model)
        self.attn = CausalSelfAttention(cfg)
        self.ln2 = nn.LayerNorm(cfg.d_model)
        self.mlp = nn.Sequential(
            nn.Linear(cfg.d_model, cfg.d_ff), nn.GELU(),
            nn.Linear(cfg.d_ff, cfg.d_model), nn.Dropout(cfg.dropout),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.attn(self.ln1(x))
        x = x + self.mlp(self.ln2(x))
        return x


class TinyGeneModel(nn.Module):
    """Same class for the native-unit arm and the byte-control arm; only
    `cfg.vocab_size` differs between the two runs."""

    def __init__(self, cfg: ModelConfig):
        super().__init__()
        self.cfg = cfg
        self.token_emb = nn.Embedding(cfg.vocab_size, cfg.d_model)
        self.pos_emb = nn.Embedding(cfg.context_len, cfg.d_model)
        self.drop = nn.Dropout(cfg.dropout)
        self.blocks = nn.ModuleList(Block(cfg) for _ in range(cfg.n_layers))
        self.ln_f = nn.LayerNorm(cfg.d_model)
        self.head = nn.Linear(cfg.d_model, cfg.vocab_size, bias=False)
        self.token_emb.weight = self.head.weight  # tied embeddings, standard for small LMs

    def num_parameters(self) -> int:
        return sum(p.numel() for p in self.parameters())

    def forward(self, ids: torch.Tensor, targets: torch.Tensor | None = None):
        b, t = ids.shape
        assert t <= self.cfg.context_len, (
            f"sequence length {t} exceeds context_len {self.cfg.context_len}")
        pos = torch.arange(t, device=ids.device)
        x = self.drop(self.token_emb(ids) + self.pos_emb(pos))
        for block in self.blocks:
            x = block(x)
        x = self.ln_f(x)
        logits = self.head(x)
        loss = None
        if targets is not None:
            loss = F.cross_entropy(
                logits.view(-1, logits.size(-1)), targets.view(-1), ignore_index=-100)
        return logits, loss
