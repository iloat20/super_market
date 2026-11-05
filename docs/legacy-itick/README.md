# iTick 时代的历史资料（已退役）

> 2026-11-04 起本项目的行情链路是**新浪 / 腾讯公开接口轮询**，零凭证、无 WebSocket。
> iTick 通道（`api-free.itick.org` / `api.itick.org`、WebSocket 推送、Token 鉴权）
> 已从代码中整体删除，`tool/verify_apk.py` 里有「iTick 代码必须被树摇」的断言守着。

本目录只收「万一要切回 iTick」时才用得上的东西：

- `check_token.py`：Token 探活 + 域名档位探测 + 逐只代码校验 + 字段核对。
  当前必然退出（`app_config.dart` 已无 token 常量），文件头有完整恢复步骤。

协议事实本身（帧格式、字段表、限流行为、三种「Invalid API key」的含义）记录在
README「一、iTick 协议事实」——按 README 的规则，那节是历史资料，读到的
「当时」表述不代表现状。
