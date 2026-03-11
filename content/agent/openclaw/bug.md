## gateway需要身份令牌
找到自己的验证身份的 token，放到 gui 界面的概览->网关令牌里面去就好了
```
grep -A1 '"token"' ~/.openclaw/openclaw.json
```