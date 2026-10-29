# BridgeDrop 私有中继（第一版）

这个服务在 Mac 与 iPhone 之间转发应用已加密的封包，使两个设备在不同 Wi-Fi 或蜂窝网络上也能交流。它不依赖 Apple 账户。Python 3.9 及以上即可运行，无第三方依赖。

**已实现并在本地验证的是 HTTP API、SQLite 持久化和资源限制。远程服务器、域名、HTTPS 证书及 Mac/iPhone 的真实互联网传输尚未部署或验收。** 不要把运行本机中继当成已经接通公网。

## 本地启动

在项目根目录运行，先在当前终端生成一份独立的服务器认证凭据：

```sh
export BRIDGEDROP_RELAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
python3 relay/server.py --db "$HOME/Library/Application Support/BridgeDrop/Relay/relay.sqlite3"
```

默认只监听 `127.0.0.1:47186`，供本机验证或同机 HTTPS 反向代理使用。iPhone 无法通过自己的 `127.0.0.1` 地址连接 Mac。局域网直传使用 App 自身的传输服务，不需要开放此中继端口。

App 的“互联网中继”设置填入服务器入口及这份认证凭据。Mac 上可将当前终端中的凭据复制到剪贴板，然后粘贴进 App：

```sh
printf '%s' "$BRIDGEDROP_RELAY_TOKEN" | pbcopy
```

不要把实际凭据写入代码、文档、命令行参数、截图或日志。`BRIDGEDROP_RELAY_TOKEN` 必须是 32–256 个 URL 安全字符；上面的命令使用密码学随机源生成 32 字节秘密。重新启动时应使用之前安全保存的同一份凭据；重新生成相当于撤销旧的认证凭据，需要更新 App。不要用配对密钥代替它。

健康检查不需要认证，也不返回私密数据：

```sh
curl http://127.0.0.1:47186/health
```

返回 `{"ok":true,"version":1}` 只表示服务进程可访问。

## API 与保存语义

除 `/health` 外，所有 API 都要求 `Authorization: Bearer …`。没有公共注册接口。请求使用 `Content-Type: application/json` 和单个有效的 `Content-Length`；不接受 HTTP chunked 请求体。

`pairID` 是 32 位小写十六进制。设备 ID 和请求 ID 使用带连字符的 UUID，支持 Swift 输出的大写形式，路由与封包内部字段按原字符串精确匹配。`ciphertext` 必须是标准、带必要填充的 Base64。服务不解密它。

| API | 行为 |
|---|---|
| `POST /v1/rooms/{pairID}/presence` | 请求 `{deviceID,name}`，返回 `200 {saved:true}`；设备名最多 256 个 UTF-8 字节，无控制字符。 |
| `GET /v1/rooms/{pairID}/presence` | 返回 `{devices:[{deviceID,name,lastSeen}]}`；90 秒未更新的设备不再显示，`lastSeen` 是 Unix 秒。 |
| `POST /v1/rooms/{pairID}/messages/{recipientID}` | 请求 `{requestID,senderID,packet}`，耐久保存后返回 `202 {accepted:true}`。 |
| `GET /v1/rooms/{pairID}/messages/{recipientID}?wait=20` | 返回最多 8 条未确认消息，重复读取不会删除；空队列返回 `{messages:[]}`。 |
| `POST /v1/rooms/{pairID}/responses/{requestID}` | 请求 `{packet}`；反向封包须交换发送/接收 ID。事务保存响应后返回 `200 {saved:true}`，原消息不再出现在收件队列。 |
| `GET /v1/rooms/{pairID}/responses/{requestID}?wait=20` | 有响应返回 `200 {packet}`，等待后仍无响应（包括已过期或不存在）返回 `204`，无响应体。 |

等待参数不得为负数；有效数字超过 25 秒时截断为 25 秒。长轮询在消息/响应到达时提前结束。

同一房间的同一 `requestID` 只能对应一个请求。**相同 JSON 内容的重试是幂等的；改变封包、设备、密文或路由的重试返回 `409`。** JSON 字段顺序和空白不影响相同性；重复字段被拒绝。

客户端应缓存本次请求/响应的原始加密封包，在网络失败后重发它。不要使用同一个请求 ID 重新加密：随机 nonce 会改变密文，因此即使明文相同，也会被识别为改变的重试。

响应确认后，服务释放原请求密文，仅保留原请求的 SHA-256 指纹、设备/请求 ID 和响应封包。这样已经确认的文件块不会继续占用大量空间，同时在服务重启后仍可识别相同重试及拒绝改变的重试。第一份密文是否被篡改，必须由接收端的 CryptoKit 验证；服务没有配对密钥，无法替接收端完成密码学验证。

`202 accepted` 是“中继已保存请求”，`200 saved` 是“中继已保存接收端响应”；它们本身不是文件完整保存的证明。App 应根据解密后的响应状态显示批准、进度和最终保存结果。

## 耐久性与资源上限

- SQLite 使用 WAL 和 `synchronous=FULL`；写入和确认在事务提交后才返回成功。运行时只允许一个中继进程使用同一个数据库。
- 单个 HTTP 请求体最多 **2 MiB**，超过返回 `413`。
- 逻辑存储配额 **256 MiB**，包含封包及保守的记录开销；不足返回 `507`。这是逻辑配额，SQLite 索引、WAL 和文件系统占用会额外使用磁盘空间，应预留空间并监控磁盘。
- 每个请求及其响应从请求创建起保留最多 **24 小时**。查询时立即排除/回收过期记录；独立清理每 30 秒运行一次。过期后需要发起新请求，无法继续查询旧响应。
- 最多 **32** 个并发连接，超过返回 `503`，附 `Retry-After: 1`。读取请求超时 10 秒；长轮询最长 25 秒，连接在响应后关闭。
- 每个直接连接 IP 的令牌桶为 **60 次请求/秒、突发 120 次**；超过返回 `429`，附 `Retry-After: 1`。所有路径，包括未认证请求和健康检查，都计入限制。
- 最多 4,096 条活跃 presence、100,000 条活跃请求；达到容量返回 `507`。
- 数据库文件权限为仅当前用户读写；服务不记录请求体、认证头、密文、配对信息或实际 token。

清理是数据库层面的逻辑删除，不保证磁盘取证意义的安全擦除；SQLite、快照或运维备份可能保留历史密文。不要把 TTL 描述为绝对删除证明。

请求限流按直接连接 IP 计算，不信任客户端提交的 `X-Forwarded-For`。反向代理后的请求通常共享代理 IP，因此后端限制是额外的总上限；公网入口还应限制真实客户端 IP。

## HTTPS 受控试用示例与生产边界

Python 官方明确说明 [`http.server` 不建议用于生产](https://docs.python.org/3/library/http.server.html)。本实现是一个有访问和资源限制的参考中继；反向代理提供 HTTPS、入口限流和网络隔离，但不构成已完成的生产安全验收。面向开放用户或长期运行前，应采用受维护的服务框架/部署平台并完成安全评审、更新、故障告警和恢复验证。

提供了 [Nginx 配置示例](nginx.conf.example)：后端继续只监听环回地址，公网只开放 HTTPS；请求上限 2 MiB；代理等待 30 秒，长于中继的 25 秒长轮询。需要用自己的域名及已签发的证书路径替换示例项。此文件未在公网部署，也未在本机安装或实际验证 Nginx。

准备远程入口时还需要：

1. 选择用户授权的服务器和域名，安装 TLS 证书并确认两台设备信任它。
2. 使用独立、无特权服务账户，安全保存环境凭据，限制数据库目录权限；外网不开放 47186。
3. 使用进程管理器保持服务运行，按实际负载设置入口连接/请求限额并监控磁盘。
4. 不记录认证头、配对码或内容；确认代理和云平台日志同样遵守这个要求。
5. 在不同网络上的真实 Mac 和 iPhone 验证批准、发送、取消、切换网络、重连及保存结果。

同一服务器 token 是私有中继的信任边界：持有它的人可使用中继 API。房间随机 ID 不是独立的用户授权系统。请仅用于自己的设备或受信任的小范围设备；本版不适合作为互不信任用户共用的公共服务。

应用层端到端密钥只保存在配对设备；HTTPS 仍用于保护服务器认证凭据和传输链路。服务能够看见设备/房间 ID、在线时间、封包大小和连接 IP。不要声称中继不知道所有元数据。

## 运行验证

在项目根目录：

```sh
python3 -m unittest discover -s relay/tests -v
```

测试启动真实的环回 HTTP 服务并使用临时 SQLite 文件，验证认证、路由字段不符、改变的重试、重启后保存、读队列不确认、响应确认、长轮询、过期回收、配额、请求体、限流和并发上限。测试封包使用合成密文，**不代表已完成真实手机、公网 TLS、云部署或密码学安全审计**。

官方配置参考：[Nginx 反向代理和超时](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)、[Nginx 请求限流](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)、[Nginx 请求体上限](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size)。
