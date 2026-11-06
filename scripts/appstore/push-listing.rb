#!/usr/bin/env ruby
# Sube la ficha de la App Store (textos, URLs, categoría, precio gratis) desde
# listing-<locale>.json a App Store Connect por la API. Idempotente: actualiza lo
# que ya existe. No envía a revisión.
#
# Uso: ruby scripts/appstore/push-listing.rb [MAC_OS|IOS] [listing.json]
require "openssl"
require "json"
require "net/http"
require "base64"

KEY_ID = ENV.fetch("ASC_KEY_ID", "576N2X283X")
ISSUER = ENV.fetch("ASC_ISSUER_ID", "0cfaa54f-c1ad-4ebd-84f8-c6b6c5530a1e")
KEY = OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")))
APP_ID = "6831410935"
PLATFORM = ARGV[0] || "MAC_OS"
LISTING = JSON.parse(File.read(ARGV[1] || File.join(__dir__, "listing-es-MX.json")))
VERSION = ENV.fetch("ARGOS_VERSION") { File.read(File.join(__dir__, "../../project.yml"))[/MARKETING_VERSION: "([^"]+)"/, 1] }

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

def upsert_localization(collection_path, type, parent_rel, parent_id, attrs)
  existing = api("GET", collection_path)["data"].find { |l| l["attributes"]["locale"] == LISTING["locale"] }
  if existing
    api("PATCH", "/v1/#{type}/#{existing['id']}", { data: { type: type, id: existing["id"], attributes: attrs } })
  else
    api("POST", "/v1/#{type}", { data: { type: type, attributes: attrs.merge(locale: LISTING["locale"]),
                                          relationships: { parent_rel => { data: { type: parent_rel == :appInfo ? "appInfos" : "appStoreVersions", id: parent_id } } } } })
  end
end

# 1. Versión de la plataforma: número de versión y copyright.
version = api("GET", "/v1/apps/#{APP_ID}/appStoreVersions?filter[platform]=#{PLATFORM}")["data"]
            .find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) }
abort "✘ No hay versión editable para #{PLATFORM}" unless version
api("PATCH", "/v1/appStoreVersions/#{version['id']}",
    { data: { type: "appStoreVersions", id: version["id"], attributes: { versionString: VERSION, copyright: LISTING["copyright"] } } })
puts "✔ Versión #{PLATFORM} → #{VERSION}"

# 2. Textos de la versión.
upsert_localization("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                    :appStoreVersion, version["id"],
                    description: LISTING["description"], keywords: LISTING["keywords"],
                    promotionalText: LISTING["promotionalText"], supportUrl: LISTING["supportUrl"],
                    marketingUrl: LISTING["marketingUrl"])
puts "✔ Descripción, palabras clave y URLs (#{LISTING['locale']})"

# 3. Información de la app: subtítulo, privacidad y categoría.
info = api("GET", "/v1/apps/#{APP_ID}/appInfos")["data"].first
upsert_localization("/v1/appInfos/#{info['id']}/appInfoLocalizations", "appInfoLocalizations", :appInfo, info["id"],
                    name: LISTING["name"], subtitle: LISTING["subtitle"], privacyPolicyUrl: LISTING["privacyPolicyUrl"])
api("PATCH", "/v1/appInfos/#{info['id']}",
    { data: { type: "appInfos", id: info["id"],
              relationships: { primaryCategory: { data: { type: "appCategories", id: "DEVELOPER_TOOLS" } },
                               secondaryCategory: { data: { type: "appCategories", id: "UTILITIES" } } } } })
puts "✔ Subtítulo, política de privacidad y categorías (Herramientas para desarrolladores / Utilidades)"

# 4. Precio: gratis en todos los territorios.
free = api("GET", "/v1/apps/#{APP_ID}/appPricePoints?filter[territory]=USA&limit=200")["data"]
         .find { |p| p["attributes"]["customerPrice"].to_f.zero? }
api("POST", "/v1/appPriceSchedules", {
  data: { type: "appPriceSchedules",
          relationships: { app: { data: { type: "apps", id: APP_ID } },
                           baseTerritory: { data: { type: "territories", id: "USA" } },
                           manualPrices: { data: [{ type: "appPrices", id: "${precio-gratis}" }] } } },
  included: [{ type: "appPrices", id: "${precio-gratis}",
               attributes: { startDate: nil },
               relationships: { appPricePoint: { data: { type: "appPricePoints", id: free["id"] } } } }]
})
puts "✔ Precio: gratis"

# 5. Notas para la revisión.
detail = api("GET", "/v1/appStoreVersions/#{version['id']}/appStoreReviewDetail")["data"] rescue nil
review_attrs = { notes: LISTING["reviewNotes"] }
if detail
  api("PATCH", "/v1/appStoreReviewDetails/#{detail['id']}", { data: { type: "appStoreReviewDetails", id: detail["id"], attributes: review_attrs } })
else
  api("POST", "/v1/appStoreReviewDetails", { data: { type: "appStoreReviewDetails", attributes: review_attrs,
                                                     relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version["id"] } } } } })
end
puts "✔ Notas para la revisión"
