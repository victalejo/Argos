#!/usr/bin/env ruby
# Sube las capturas de screenshots/<plataforma>/*.png (orden alfabético) a la versión
# editable de App Store Connect, reemplazando las que hubiera en ese set.
#
# Uso: ruby scripts/appstore/push-screenshots.rb [MAC_OS|IOS] [locale] [displayType]
#   Mac: 2560x1600 (u otro tamaño 16:10 aceptado), displayType APP_DESKTOP.
require "openssl"
require "json"
require "net/http"
require "base64"
require "digest"

KEY_ID = ENV.fetch("ASC_KEY_ID", "576N2X283X")
ISSUER = ENV.fetch("ASC_ISSUER_ID", "0cfaa54f-c1ad-4ebd-84f8-c6b6c5530a1e")
KEY = OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")))
APP_ID = "6831410935"
PLATFORM = ARGV[0] || "MAC_OS"
LOCALE = ARGV[1] || "es-MX"
DISPLAY_TYPE = ARGV[2] || (PLATFORM == "MAC_OS" ? "APP_DESKTOP" : "APP_IPHONE_67")
DIR = File.join(__dir__, "screenshots", PLATFORM == "MAC_OS" ? "mac" : "ios")

def b64(s); Base64.urlsafe_encode64(s, padding: false); end

def token
  now = Time.now.to_i
  input = "#{b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }.to_json)}.#{b64({ iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }.to_json)}"
  asn = OpenSSL::ASN1.decode(KEY.sign(OpenSSL::Digest::SHA256.new, input))
  "#{input}.#{b64(asn.value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..-1] }.join)}"
end

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
  abort "✘ #{method} #{path} → #{res.code}: #{data['errors']&.map { |e| e['detail'] }&.join('; ')}" unless res.code.start_with?("2")
  data
end

# Sube los trozos que indica Apple (uploadOperations) a sus URLs firmadas.
def upload_parts(operations, bytes)
  operations.each do |op|
    uri = URI(op["url"])
    req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
    op["requestHeaders"].each { |h| req[h["name"]] = h["value"] }
    req.body = bytes.byteslice(op["offset"], op["length"])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    abort "✘ Subida de trozo → #{res.code}" unless res.code.start_with?("2")
  end
end

files = Dir[File.join(DIR, "*.png")].sort
abort "✘ No hay capturas en #{DIR}" if files.empty?

version = api("GET", "/v1/apps/#{APP_ID}/appStoreVersions?filter[platform]=#{PLATFORM}")["data"]
            .find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) }
abort "✘ No hay versión editable para #{PLATFORM}" unless version
loc = api("GET", "/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations")["data"]
        .find { |l| l["attributes"]["locale"] == LOCALE }
abort "✘ No hay localización #{LOCALE}; ejecuta antes push-listing.rb" unless loc

set = api("GET", "/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets")["data"]
        .find { |s| s["attributes"]["screenshotDisplayType"] == DISPLAY_TYPE }
set ||= api("POST", "/v1/appScreenshotSets", {
  data: { type: "appScreenshotSets", attributes: { screenshotDisplayType: DISPLAY_TYPE },
          relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc["id"] } } } }
})["data"]

api("GET", "/v1/appScreenshotSets/#{set['id']}/appScreenshots")["data"].each do |old|
  api("DELETE", "/v1/appScreenshots/#{old['id']}")
end

files.each do |path|
  bytes = File.binread(path)
  shot = api("POST", "/v1/appScreenshots", {
    data: { type: "appScreenshots", attributes: { fileName: File.basename(path), fileSize: bytes.bytesize },
            relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set["id"] } } } }
  })["data"]
  upload_parts(shot["attributes"]["uploadOperations"], bytes)
  api("PATCH", "/v1/appScreenshots/#{shot['id']}", {
    data: { type: "appScreenshots", id: shot["id"], attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) } }
  })
  puts "✔ #{File.basename(path)}"
end
puts "✔ #{files.size} capturas en #{DISPLAY_TYPE} (#{LOCALE}). Apple las procesa en unos minutos."
