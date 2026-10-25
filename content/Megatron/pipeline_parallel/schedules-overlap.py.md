在config内的pp大于1的时会打开interleving，
```mermaid
graph TB
    %% --- Nodes outside子图 ---
    Start([Start])
    End([End])

    %% --- Warm‑up Phase ---
    subgraph Warmup["Warm‑up Phase (sm_free_p2p)"]
      direction TB
      W0["recv_forwardA() -> input_tensors[0]"]
      W1{{"k < num_warmup_microbatches"}}
      W2["wait recv_prev_finished == 0"]
      W3["forward_step_helper(k)"]
      W4["send_forward_recv_forwardA() -> send_next_finished"]
      W5["append input_tensor to next chunk"]
      W6["send_backward_recv_backwardA() -> send_prev_finished / recv_next_finished"]

      W0 --> W1
      W1 --> W2 --> W3 --> W4 -->W6 --> W5 --> W1
    end

    %% --- Steady 1F1B ---
    subgraph Steady["1F1B Steady‑State (sm_free_p2p)"]
      direction TB
      S0{{"k < num_microbatches_remaining"}}
      S1["wait recv_prev_finished == 0"]
      S2["forward_step_helper(k)"]
      S3["send_forward_recv_forwardA()"]
      S4["wait recv_next_finished == 0"]
      S5["backward_step_helper(k)"]
      S6["send_backward_recv_backwardA() -> send_prev_finished"]
      S7["append tensors / grads"]

      S0 --> S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S0
    end

    %% --- Cool‑down Flush ---
    subgraph Cooldown["Cooldown Flush (sm_free_p2p)"]
      direction TB
      C0["recv_backwardA() -> output_tensor_grads"]
      C1{{"remaining backward microbatches"}}
      C2["wait recv_next_finished == 0"]
      C3["backward_step_helper(k)"]
      C4["send_backward_recv_backwardA()"]

      C0 --> C1
      C1 --> C2 --> C3 --> C4 --> C1
    end

    %% --- Stage links ---
    Start --> W0
    W5 -.-> S0
    S7 -.-> C0
    C4 --> End
```
```txt
时间         PP0 (rank0-3)           ┆          PP1 (rank4-7)
--------------------------------------------------------------------
t=0          FWD MB0  ──────────►    ┆         （等待）
t=1          FWD MB1  ──────────►    ┆  FWD MB0
t=2          (等梯度)   ◄── BWD MB0   ┆  FWD MB1
t=3          BWD MB0                 ┆  BWD MB1
t=4          BWD MB1  （完成）        ┆  （完成）
```