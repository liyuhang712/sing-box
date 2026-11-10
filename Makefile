# 程序名称、当前提交和默认构建标签。
NAME = sing-box
COMMIT = $(shell git rev-parse --short HEAD)
TAGS ?= $(shell cat release/DEFAULT_BUILD_TAGS_OTHERS)

# 版本读取工具在构建主机上运行；目标平台仍由构建时的 GOOS 和 GOARCH 决定。
GOHOSTOS = $(shell go env GOHOSTOS)
GOHOSTARCH = $(shell go env GOHOSTARCH)
VERSION=$(shell CGO_ENABLED=0 GOOS=$(GOHOSTOS) GOARCH=$(GOHOSTARCH) go run github.com/sagernet/sing-box/cmd/internal/read_tag@latest)

# 共享链接参数、主程序构建参数及可覆盖的工具和安装路径。
LDFLAGS_SHARED = $(shell cat release/LDFLAGS)
PARAMS = -v -trimpath -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=$(VERSION)' $(LDFLAGS_SHARED) -s -w -buildid="
MAIN_PARAMS = $(PARAMS) -tags "$(TAGS)"
MAIN = ./cmd/sing-box
PREFIX ?= $(shell go env GOPATH)
SING_FFI ?= sing-ffi
LIBBOX_FFI_CONFIG ?= ./experimental/libbox/ffi.json

.PHONY: test release docs build schema

# 构建主程序；race 版本启用竞态检测，CI 构建分别验证默认和指定标签。
build:
	export GOTOOLCHAIN=local && \
	go build $(MAIN_PARAMS) $(MAIN)

race:
	export GOTOOLCHAIN=local && \
	go build -race $(MAIN_PARAMS) $(MAIN)

ci_build:
	export GOTOOLCHAIN=local && \
	go build $(PARAMS) $(MAIN) && \
	go build $(MAIN_PARAMS) $(MAIN)

# 生成命令补全和配置文件 JSON Schema。
generate_completions:
	go run -v --tags "$(TAGS),generate,generate_completions" $(MAIN)

schema:
	go run -ldflags "$(LDFLAGS_SHARED)" --tags "$(TAGS)" $(MAIN) schema -o docs/schema.json

# 将主程序安装到指定前缀的 bin 目录。
install:
	go build -o $(PREFIX)/bin/$(NAME) $(MAIN_PARAMS) $(MAIN)

# 格式化代码和文档，并对多个目标平台执行静态检查。
fmt:
	@golangci-lint fmt

fmt_docs:
	go run ./cmd/internal/format_docs

lint:
	GOOS=linux golangci-lint run ./...
	GOOS=android golangci-lint run ./...
	GOOS=windows golangci-lint run ./...
	GOOS=darwin golangci-lint run ./...
#	GOOS=freebsd golangci-lint run ./...

# 安装静态检查工具。
lint_install:
	go install -v github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest

# 生成并格式化 Protocol Buffers 代码，或安装所需生成器。
proto:
	@go run ./cmd/internal/protogen
	@golangci-lint fmt

proto_install:
	go install -v google.golang.org/protobuf/cmd/protoc-gen-go@latest
	go install -v google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# 更新内置证书数据。
update_certificates:
	go run ./cmd/internal/update_certificates

# 构建发布包并上传预发布草稿；release_repo 使用单独的仓库发布配置。
release:
	go run ./cmd/internal/build goreleaser release --clean --skip publish
	mkdir dist/release
	mv dist/*.tar.gz \
		dist/*.zip \
		dist/*.deb \
		dist/*.rpm \
		dist/*_amd64.pkg.tar.zst \
		dist/*_arm64.pkg.tar.zst \
		dist/release
	ghr --replace --draft --prerelease -p 5 "v${VERSION}" dist/release
	rm -r dist/release

release_repo:
	go run ./cmd/internal/build goreleaser release -f .goreleaser.fury.yaml --clean

# 安装发布上传工具。
release_install:
	go install -v github.com/tcnksm/ghr@latest

# 更新 Android 和桌面客户端版本。
update_android_version:
	go run ./cmd/internal/update_android_version

update_desktop_version:
	go run ./cmd/internal/update_desktop_version

# 构建 Android 安装包、上传发布草稿或发布到 Google Play。
build_android:
	cd ../sing-box-for-android && ./gradlew :app:clean :app:assembleOtherRelease :app:assembleOtherLegacyRelease && ./gradlew --stop

upload_android:
	mkdir -p dist/release_android
	cp ../sing-box-for-android/app/build/outputs/apk/other/release/*.apk dist/release_android
	cp ../sing-box-for-android/app/build/outputs/apk/otherLegacy/release/*.apk dist/release_android
	VERSION_CODE=$$(grep VERSION_CODE ../sing-box-for-android/version.properties | cut -d= -f2); \
	VERSION_NAME=$$(grep VERSION_NAME ../sing-box-for-android/version.properties | cut -d= -f2); \
	printf '{\n  "version_code": %s,\n  "version_name": "%s"\n}\n' "$$VERSION_CODE" "$$VERSION_NAME" > dist/release_android/SFA-version-metadata.json
	ghr --replace --draft --prerelease -p 5 "v${VERSION}" dist/release_android
	rm -rf dist/release_android

release_android: build_android upload_android

publish_android:
	cd ../sing-box-for-android && ./gradlew :app:publishPlayReleaseBundle && ./gradlew --stop

# 构建并发布 iOS 客户端及越狱设备安装包。
# TODO: find why and remove `-destination 'generic/platform=iOS'`
# TODO: remove xcode clean when fix control widget fixed
build_ios:
	cd ../sing-box-for-apple && \
	rm -rf build/SFI.xcarchive && \
	xcodebuild clean -scheme SFI -derivedDataPath build/SFI.dd && \
	xcodebuild archive -scheme SFI -configuration Release -destination 'generic/platform=iOS' -archivePath build/SFI.xcarchive -derivedDataPath build/SFI.dd -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_ios_app_store:
	cd ../sing-box-for-apple && \
	xcodebuild -exportArchive -archivePath build/SFI.xcarchive -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

build_ios_deb:
	$(MAKE) -C ../sing-box-for-apple build_ios_deb

upload_ios_deb:
	ghr --replace --draft --prerelease "v${VERSION}" ../sing-box-for-apple/build/jailbreak/"SFI-${VERSION}-iphoneos-arm64.deb"
	ghr --replace --draft --prerelease "v${VERSION}" ../sing-box-for-apple/build/jailbreak/"SFI-${VERSION}-iphoneos-arm64e.deb"

release_ios: build_ios upload_ios_app_store

release_ios_deb: build_ios_deb upload_ios_deb

# 构建并发布 macOS App Store 版本。
build_macos:
	cd ../sing-box-for-apple && \
	rm -rf build/SFM.xcarchive && \
	xcodebuild archive -scheme SFM -configuration Release -archivePath build/SFM.xcarchive -derivedDataPath build/SFM.dd -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_macos_app_store:
	cd ../sing-box-for-apple && \
	xcodebuild -exportArchive -archivePath build/SFM.xcarchive -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

release_macos: build_macos upload_macos_app_store

# 构建、签名公证和上传独立版 macOS 安装包及调试符号。
build_macos_standalone:
	$(MAKE) -C ../sing-box-for-apple archive_macos_standalone

build_macos_dmg:
	$(MAKE) -C ../sing-box-for-apple build_macos_dmg

build_macos_pkg:
	$(MAKE) -C ../sing-box-for-apple build_macos_pkg

notarize_macos_dmg:
	$(MAKE) -C ../sing-box-for-apple notarize_macos_dmg

notarize_macos_pkg:
	$(MAKE) -C ../sing-box-for-apple notarize_macos_pkg

upload_macos_dmg:
	mkdir -p dist/SFM
	cp ../sing-box-for-apple/build/SFM-Apple.dmg "dist/SFM/SFM-${VERSION}-Apple.dmg"
	cp ../sing-box-for-apple/build/SFM-Intel.dmg "dist/SFM/SFM-${VERSION}-Intel.dmg"
	cp ../sing-box-for-apple/build/SFM-Universal.dmg "dist/SFM/SFM-${VERSION}-Universal.dmg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Apple.dmg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Intel.dmg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Universal.dmg"

upload_macos_pkg:
	mkdir -p dist/SFM
	cp ../sing-box-for-apple/build/SFM-Apple.pkg "dist/SFM/SFM-${VERSION}-Apple.pkg"
	cp ../sing-box-for-apple/build/SFM-Intel.pkg "dist/SFM/SFM-${VERSION}-Intel.pkg"
	cp ../sing-box-for-apple/build/SFM-Universal.pkg "dist/SFM/SFM-${VERSION}-Universal.pkg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Apple.pkg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Intel.pkg"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}-Universal.pkg"

replace_macos_pkg:
	mkdir -p dist/SFM
	cp ../sing-box-for-apple/build/SFM-Apple.pkg "dist/SFM/SFM-${VERSION}-Apple.pkg"
	cp ../sing-box-for-apple/build/SFM-Intel.pkg "dist/SFM/SFM-${VERSION}-Intel.pkg"
	cp ../sing-box-for-apple/build/SFM-Universal.pkg "dist/SFM/SFM-${VERSION}-Universal.pkg"
	ghr --replace "v${VERSION}" "dist/SFM/SFM-${VERSION}-Apple.pkg"
	ghr --replace "v${VERSION}" "dist/SFM/SFM-${VERSION}-Intel.pkg"
	ghr --replace "v${VERSION}" "dist/SFM/SFM-${VERSION}-Universal.pkg"

upload_macos_dsyms:
	mkdir -p dist/SFM
	cd ../sing-box-for-apple/build/SFM.System-universal.xcarchive && zip -r SFM.dSYMs.zip dSYMs
	cp ../sing-box-for-apple/build/SFM.System-universal.xcarchive/SFM.dSYMs.zip "dist/SFM/SFM-${VERSION}.dSYMs.zip"
	ghr --replace --draft --prerelease "v${VERSION}" "dist/SFM/SFM-${VERSION}.dSYMs.zip"

replace_macos_dsyms:
	mkdir -p dist/SFM
	cd ../sing-box-for-apple/build/SFM.System-universal.xcarchive && zip -r SFM.dSYMs.zip dSYMs
	cp ../sing-box-for-apple/build/SFM.System-universal.xcarchive/SFM.dSYMs.zip "dist/SFM/SFM-${VERSION}.dSYMs.zip"
	ghr --replace "v${VERSION}" "dist/SFM/SFM-${VERSION}.dSYMs.zip"

release_macos_standalone: build_macos_pkg notarize_macos_pkg upload_macos_pkg upload_macos_dsyms

replace_macos_standalone: build_macos_pkg notarize_macos_pkg upload_macos_pkg upload_macos_dsyms

# 构建和发布 tvOS 客户端，或导出并上传 IPA。
build_tvos:
	cd ../sing-box-for-apple && \
	rm -rf build/SFT.xcarchive && \
	xcodebuild archive -scheme SFT -configuration Release -archivePath build/SFT.xcarchive -derivedDataPath build/SFT.dd -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_tvos_app_store:
	cd ../sing-box-for-apple && \
	xcodebuild -exportArchive -archivePath "build/SFT.xcarchive" -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

export_tvos_ipa:
	cd ../sing-box-for-apple && \
	xcodebuild -exportArchive -archivePath "build/SFT.xcarchive" -exportOptionsPlist SFI/Export.plist -allowProvisioningUpdates -exportPath build/SFT && \
	cp build/SFT/sing-box.ipa dist/SFT.ipa

upload_tvos_ipa:
	cd dist && \
	cp SFT.ipa "SFT-${VERSION}.ipa" && \
	ghr --replace --draft --prerelease "v${VERSION}" "SFT-${VERSION}.ipa"

release_tvos: build_tvos upload_tvos_app_store

# 更新 Apple 客户端版本并组合执行发布流程。
update_apple_version:
	go run ./cmd/internal/update_apple_version

update_macos_version:
	MACOS_PROJECT_VERSION=$(shell go run ./cmd/internal/app_store_connect next_project_version macos) go run ./cmd/internal/update_apple_version

release_apple: lib_apple update_apple_version release_ios release_macos release_tvos release_macos_standalone

release_apple_beta: update_apple_version release_ios release_macos release_tvos

# 管理 TestFlight 和 App Store 的提交与发布。
publish_testflight:
	go run -v ./cmd/internal/app_store_connect publish_testflight $(filter-out $@,$(MAKECMDGOALS))

submit_app_store:
	go run -v ./cmd/internal/app_store_connect submit_app_store $(filter-out $@,$(MAKECMDGOALS))

release_app_store: release_ios release_tvos submit_app_store

publish_app_store:
	go run -v ./cmd/internal/app_store_connect publish_app_store $(filter-out $@,$(MAKECMDGOALS))

# 运行主模块和 test 模块的测试；test_stdio 额外启用 force_stdio 标签。
test:
	@go test -v ./... && \
	cd test && \
	go mod tidy && \
	go test -v -tags "$(TAGS_TEST)" .

test_stdio:
	@go test -v ./... && \
	cd test && \
	go mod tidy && \
	go test -v -tags "$(TAGS_TEST),force_stdio" .

# 构建各平台 libbox 库，或通过 sing-ffi 生成平台绑定。
lib_android:
	go run ./cmd/internal/build_libbox -target android

lib_apple:
	go run ./cmd/internal/build_libbox -target apple

lib_windows:
	$(SING_FFI) generate --config $(LIBBOX_FFI_CONFIG) --platform-type csharp

lib_android_new:
	$(SING_FFI) generate --config $(LIBBOX_FFI_CONFIG) --platform-type android

lib_apple_new:
	$(SING_FFI) generate --config $(LIBBOX_FFI_CONFIG) --platform-type apple

# 安装移动平台库构建工具。
lib_install:
	go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
	go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.13

# 本地预览、发布文档或安装文档依赖。
docs:
	venv/bin/mkdocs serve

publish_docs:
	venv/bin/mkdocs gh-deploy -m "Update" --force --ignore-version --no-history

docs_install:
	python3 -m venv venv
	source ./venv/bin/activate && pip install --force-reinstall mkdocs-material=="9.7.2" mkdocs-static-i18n=="1.2.*"

# 清理构建产物；update 会重置并清理工作区。
clean:
	rm -rf bin dist sing-box
	rm -f $(shell go env GOPATH)/sing-box

update:
	git fetch
	git reset FETCH_HEAD --hard
	git clean -fdx

# 接受未定义的目标，供需要将额外参数作为目标传入的命令使用。
%:
	@:
