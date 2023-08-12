require 'net/http'
require 'uri'

class TinderAccount < ApplicationRecord
  enum status: {
    active: 'active',
    age_restricted: 'age_restricted',
    banned: 'banned',
    captcha_required: 'captcha_required',
    identity_verification: 'identity_verification',
    logged_out: 'logged_out',
    phone_verify_required: 'phone_verify_required',
    out_of_likes: 'out_of_likes',
    limit_of_likes: 'limit_of_likes',
    profile_deleted: 'profile_deleted',
    proxy_error: 'proxy_error',
    shadowbanned: 'shadowbanned',
    under_review: 'under_review',
    verification_required: 'verification_required',
  }, _prefix: :status

  belongs_to :fan_model, optional: true
  belongs_to :location, optional: true
  has_many :account_status_updates, dependent: :delete_all
  has_many :swipe_jobs, dependent: :destroy
  has_many :matches, dependent: :delete_all
  has_many :runs, through: :swipe_jobs, dependent: :destroy

  before_destroy :cancel_swipe_jobs

  def cancel_swipe_jobs
    swipe_jobs.each(&:cancel!)
  end

  validates :gologin_profile_id, uniqueness: true, presence: true
  validates :location, uniqueness: { scope: [:fan_model] }, allow_blank: true
  # validates :fan_model, presence: true
  validates :status, presence: true

  PHONE_REGEX = /\A\d{8,45}\z/
  validates :number,
    format: { with: PHONE_REGEX, message: "phone number must contain only numbers and be at least 8 digits long" },
    allow_nil: true

  REGEX = /\A[a-z0-9]{24}+\z/
  validates :gologin_profile_id, format: { with: REGEX, message: "gologin must be 24 character 0-9a-z" }

  belongs_to :user
  belongs_to :schedule, optional: true

  scope :alive, -> { where.not(status: 'profile_deleted') }
  scope :active, -> { where(status: ['active', 'out_of_likes', 'limit_of_likes']) }
  scope :banned, -> { where(status: ['banned', 'age_restricted']) }
  scope :captcha, -> { where(status: 'captcha_required') }
  scope :identity, -> { where(status: 'identity_verification') }
  scope :logged_out, -> { where(status: 'logged_out') }
  scope :phone_verify_required, -> { where(status: 'phone_verify_required') }
  scope :not_deleted, -> { where.not(status: 'profile_deleted') }
  scope :not_scheduled, -> { where(schedule_id: nil) }
  scope :out_of_likes, -> { where(status: 'out_of_likes') }
  scope :profile_deleted, -> { where(status: 'profile_deleted') }
  scope :proxy_error, -> { alive.where(proxy_active: false) }
  scope :shadowbanned, -> { where(status: 'shadowbanned') }
  scope :scheduled, -> { alive.where.not(schedule_id: nil) }
  scope :under_review, -> { where(status: 'under_review') }
  scope :warm_up, -> { where(warm_up: true) }
  scope :no_gold, -> { where(gold: false, status: ['active', 'out_of_likes', 'banned', 'age_restricted', 'captcha_required', 'identity_verification', 'logged_out', 'phone_verify_required', 'shadowbanned', 'under_review']) }
  scope :gold, -> { where(gold: true, status: ['active', 'out_of_likes', 'banned', 'age_restricted', 'captcha_required', 'identity_verification', 'logged_out', 'phone_verify_required', 'shadowbanned', 'under_review']) }
  scope :running, -> { where(swipe_jobs) }

  def k8s
    K8sAccount.new(self)
  end

  def previous_status
    account_status_updates.where.not(before_status: 'proxy_error').order("id desc").limit(1).first.before_status
  end

  def title
    return "#{gologin_profile_name} #{status}" if gologin_profile_name
    return "#{id} #{fan_model.name} #{status}" if fan_model
    "#{id} #{status}"
  end

  def check_status!
    running = self.swipe_jobs.where(status: ['pending', 'running', 'queued'])

    if running.any?
      errors.add(:check_status, "account is already running a job #{running.pluck(:id).join(",")}")
    else
      SwipeJob.create(
        tinder_account: self,
        job_type: "status_check",
        user: self.user,
        vps_info: VpsInfo.status_checker_vps(self.user),
        warm_up: self.warm_up,
        created_by: :user
      )
    end
  end

  def self.counts_by_date
    query = """
      select status, array_agg(count) from (
          select d.date, s.status, count(t.status)
          FROM (
              select distinct status
              from tinder_accounts
              where status not in ('profile_deleted', 'proxy_error', 'logged_out', 'phone_verify_required', 'banned')
          ) s
          cross join (
              SELECT t.day::date date
              FROM generate_series(
                  timestamp '2022-05-28',
                  timestamp '2022-06-10',
                  interval  '1 day'
              ) AS t(day)
          ) d
          left outer join (
              select distinct on (
                  tinder_accounts.id,
                  date_trunc('day', asu.created_at)
              ) tinder_accounts.id,
              date_trunc('day', asu.created_at) date,
              asu.status
              from tinder_accounts
              join account_status_updates asu on asu.tinder_account_id = tinder_accounts.id
              where asu.status not in ('profile_deleted', 'proxy_error')
              and user_id = 3
              order by date_trunc('day', asu.created_at)
          ) t on d.date = t.date and s.status = t.status
          group by d.date, s.status
          order by d.date
          -- GROUP BY d.date, s.status
          -- ORDER BY d.date
      )t
      group by status
      ;
    """
    res = ActiveRecord::Base.connection.execute(query)
    res.values.to_h.transform_values { |v| v.gsub(/{|}/, "").split(",").map(&:to_i) }
  end

  def self.datasets
    colors = %w(red blue gray green lightblue blueviolet coral yellow salmon gold khaki)
    i= 0
    counts_by_date.map do |k,v|
      x = {
          label: k,
          backgroundColor: colors[i],
          borderColor: colors[i],
          borderWidth: 1,
          data: v,
      }
      i+= 1
      x
    end
  end

  def self.update_counts(last_hours)
    updated_accounts = joins(:swipe_jobs).where("swipe_jobs.created_at > ?", last_hours.hours.ago).distinct
    puts "updating #{updated_accounts.count} accounts with jobs created in the last #{last_hours} hours"
    updated_accounts.find_each do |ta|
      ta.update_column(:total_swipes, ta.swipe_jobs.sum(:swipes))
    end
  end

  # TinderAccount.where(user_id: 5).map {|t| t.update_gologin_name ; sleep(0.5) }

  def update_gologin_name
    return unless (user.name == "Robert" || user.name == "Robert2" || fan_model.try(:name) == "Nika" || user.name == "Prince" || user.name == "Frank")
    return if status == "profile_deleted"

    shortname =
      case status
      when "active"
        "ACTIVE"
      when "age_restricted"
        "AGE"
      when "banned"
        "BANNED"
      when "captcha_required"
        "CAPTCHA"
      when "identity_verification"
        "IDENTITY"
      when "logged_out"
        "LOGGEDOUT"
      when "phone_verify_required"
        "PHONEVERIFYREQUIRED"
      when "out_of_likes"
        "ACTIVE"
      when "profile_deleted"
        "DELETED"
      when "proxy_error"
        "PROXY"
      when "shadowbanned"
        "SB"
      when "limit_of_likes"
        "LOL"
      when "under_review"
        "UNDER_REVIEW"
      when "verification_required"
        "VERIFICATION"
      else
        return
      end

    if gologin_profile_name.match /^\s?#{shortname} \//
      puts "skipping #{gologin_profile_name}" if ENV['DEBUG']
      return
    end

    names = gologin_profile_name.split(' / ')
    orig_name = names[names.length() - 1]
    
    new_name = "#{shortname} / #{orig_name}"

    uri = URI.parse("https://api.gologin.com/browser/#{gologin_profile_id}/name")
    request = Net::HTTP::Patch.new(uri)
    request["Accept"] = "*/*"
    request.content_type = "application/json"
    request["Authorization"] = "Bearer #{user.gologin_api_token}"
    request.body = JSON.dump({ 
      "name" => new_name,
      "geolocation" => {
        "mode" => "prompt",
        "enabled" => true,
        "fillBasedOnIp" => true,
        "customize" => true,
        "latitude" => 0,
        "longitude" => 0,
        "accuracy" => 10
      },
    })
    req_options = { use_ssl: uri.scheme == "https", }

    begin
      # puts "updating #{gologin_profile_name} status:#{status}"
      puts "#{orig_name}      *****     #{new_name} "
      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      if response.code.to_i == 200
        self.update(gologin_profile_name: new_name)
      end
    rescue
      puts "error syncing profile #{id} #{status}"
    end
  end

  def create_proxy
    uri = URI.parse("https://api.gologin.com/browser/#{gologin_profile_id}/proxy")
    request = Net::HTTP::Patch.new(uri)
    request["Accept"] = "*/*"
    request.content_type = "application/json"
    request["Authorization"] = "Bearer #{user.gologin_api_token}"
    request.body = JSON.dump({ 
      "autoProxyRegion" => proxy_auto_region,
      "host" => proxy_host,
      "mode" => proxy_mode,
      "password" => proxy_password,
      "port" => proxy_port,
      "torProxyRegion" => proxy_tor_region,
      "username" => proxy_username
    })
    req_options = { use_ssl: uri.scheme == "https", }

    begin
      # puts "updating #{gologin_profile_name} status:#{status}"
      puts "add proxy"
      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      if response.code.to_i == 200
        put "proxy updated"
      end
    rescue
      puts "error syncing profile #{id} #{status}"
    end
  end

  def create_profile
    uri = URI.parse("https://api.gologin.com/browser/")
    request = Net::HTTP::Post.new(uri)
    request["Accept"] = "*/*"
    request.content_type = "application/json"
    request["Authorization"] = "Bearer #{user.gologin_api_token}"
    request.body = JSON.dump({ 
      "name" => self.gologin_profile_name,
      "browserType" => "chrome",
      "canBeRunnin" => true,
      "os" => "win",
      "proxyEnabled" => true,
      "googleServicesEnabled" => false,
      "startUrl" => "",
      "lockEnabled" => false,
      "dns" => "",
      "proxy"=> {
        "mode" => "none",
        "host" => "",
        "port" => 80,
        "username" => "",
        "password" => "",
        "autoProxyRegion" => "us",
        "torProxyRegion" => "us"
      },
      "geoProxyInfo" => {
        "connection" => "",
        "country" => "",
        "region" => "",
        "city" => ""
      },
      "isM1" => false,
      "timezone" => {
        "enabled" => true,
        "fillBasedOnIp" => true,
        "timezone" => ""
      },
      "navigator" => {
          "userAgent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.5481.77 Safari/537.36",
          "resolution" => "1366x768",
          "language" => "en-US,en;q=0.9",
          "platform" => "Win32",
          "hardwareConcurrency" => 2,
          "doNotTrack" => false,
          "deviceMemory" => 1,
          "maxTouchPoints" => 0
      },
      "canvas" => {
        "mode" => "off"
      },
      "geolocation" => {
        "mode" => "prompt",
        "enabled" => true,
        "customize" => true,
        "fillBasedOnIp" => false,
        "latitude" => self.geo_proxy_latitude,
        "longitude" => self.geo_proxy_longitude,
        "accuracy" => 10
      },
      "webRTC" => {
          "mode" => "alerted",
          "enabled" => true,
          "customize" => true,
          "localIpMasking" => true,
          "fillBasedOnIp" => true,
          "publicIp" => "",
          "localIps" => []
      },
      "webGL" => {
          "mode" => "off",
          "getClientRectsNoise" => 2.4912,
          "noise" => 81.23
      },
      "clientRects" => {
          "mode" => "off",
          "noise" => 2.4912
      },
      "webGLMetadata" => {
          "mode" => "mask",
          "vendor" => "Google Inc. (Intel)",
          "renderer" => "ANGLE (Intel, Intel(R) HD Graphics 620 Direct3D11 vs_5_0 ps_5_0, D3D11-27.20.100.8681)"
      },
      "audioContext" => {
          "mode" => "noise",
          "noise" => 1.913982021938e-8
      },
      "fonts" => {
          "enableMasking" => true,
          "enableDomRect" => true,
          "families" => [
              "AIGDT",
              "AMGDT",
              "Arial",
              "Arial Black",
              "Arial CE",
              "Arial Cyr",
              "Arial Greek",
              "Arial Hebrew",
              "Arial MT",
              "Arial Narrow",
              "Arial Rounded MT Bold",
              "Arial TUR",
              "Arial Unicode MS",
              "Calibri",
              "Calibri Light",
              "Cambria",
              "Cambria Math",
              "Candara",
              "Comic Sans MS",
              "Consolas",
              "Constantia",
              "Corbel",
              "Courier",
              "Courier New",
              "Courier New Baltic",
              "Courier New CE",
              "Courier New Cyr",
              "Courier New Greek",
              "Courier New TUR",
              "David",
              "David Libre",
              "DejaVu Sans",
              "DejaVu Sans Light",
              "DejaVu Sans Mono",
              "DejaVu Serif Condensed",
              "Ebrima",
              "Frank Ruehl",
              "Frank Ruehl Libre",
              "Frank Ruehl Libre Black",
              "Frank Ruehl Libre Light",
              "Franklin Gothic Book",
              "Franklin Gothic Demi",
              "Franklin Gothic Medium",
              "Franklin Gothic Medium Cond",
              "Gabriola",
              "Georgia",
              "Gill Sans MT",
              "Gill Sans MT Condensed",
              "Gill Sans MT Ext Condensed Bold",
              "Gill Sans Ultra Bold",
              "Gill Sans Ultra Bold Condensed",
              "KacstLetter",
              "KacstTitlel",
              "Leelawadee",
              "Liberation Mono",
              "Liberation Sans",
              "Liberation Sans Narrow",
              "Liberation Serif",
              "Lucida Bright",
              "Lucida Calligraphy",
              "Lucida Console",
              "Lucida Sans Unicode",
              "MS Gothic",
              "MS LineDraw",
              "MS Mincho",
              "MS Outlook",
              "MS PGothic",
              "MS PMincho",
              "MS Reference Sans Serif",
              "MS Reference Specialty",
              "MS Sans Serif",
              "MS Serif",
              "MV Boli",
              "Malgun Gothic",
              "Marlett",
              "Microsoft Himalaya",
              "Microsoft JhengHei",
              "Microsoft JhengHei UI",
              "Microsoft New Tai Lue",
              "Microsoft PhagsPa",
              "Microsoft Sans Serif",
              "Microsoft Tai Le",
              "Microsoft Uighur",
              "Microsoft YaHei",
              "Microsoft YaHei UI",
              "Microsoft Yi Baiti",
              "MingLiU",
              "MingLiU-ExtB",
              "MingLiU_HKSCS",
              "MingLiU_HKSCS-ExtB",
              "Miriam",
              "Miriam Fixed",
              "Miriam Libre",
              "Mongolian Baiti",
              "NSimSun",
              "Nirmala UI",
              "Noto Mono",
              "Noto Sans",
              "Noto Sans Arabic UI",
              "Noto Sans CJK HK",
              "Noto Sans CJK KR",
              "Noto Sans CJK SC",
              "Noto Sans CJK TC",
              "Noto Sans Lisu",
              "Noto Sans Mono CJK HK",
              "Noto Sans Mono CJK JP",
              "Noto Sans Mono CJK KR",
              "Noto Sans Mono CJK SC",
              "Noto Sans Mono CJK TC",
              "Noto Serif",
              "Noto Serif CJK JP",
              "Noto Serif CJK KR",
              "Noto Serif CJK SC",
              "Noto Serif CJK TC",
              "Noto Serif Georgian",
              "Noto Serif Hebrew",
              "Noto Serif Italic",
              "Noto Serif Lao",
              "OpenSymbol",
              "Oswald",
              "PMingLiU",
              "PMingLiU-ExtB",
              "Palatino",
              "Palatino Linotype",
              "Roboto",
              "Roboto Black",
              "Roboto Medium",
              "Roboto Thin",
              "Segoe Print",
              "Segoe Script",
              "Segoe UI",
              "Segoe UI Light",
              "Segoe UI Semibold",
              "Segoe UI Semilight",
              "Segoe UI Symbol",
              "SimSun",
              "SimSun-ExtB",
              "Tahoma",
              "Times New Roman",
              "Times New Roman Baltic",
              "Times New Roman CE",
              "Times New Roman Cyr",
              "Times New Roman Greek",
              "Trebuchet MS",
              "Verdana",
              "Webdings",
              "Wingdings 3",
              "Yu Gothic UI"
          ]
      },
      "mediaDevices" => {
        "enableMasking" => true,
        "audioInputs" => 1,
        "audioOutputs" => 1,
        "videoInputs" => 0
      },
      "extensions" => {
        "enabled" => true,
        "preloadCustom" => true,
        "names" => []
      },
      "storage" => {
        "local" => true,
        "extensions" => true,
        "bookmarks" => true,
        "history" => true,
        "passwords" => true,
        "session" => true,
        "indexedDb" => true
      },
      "plugins" => {
        "enableVulnerable" => true,
        "enableFlash" => true
      },
      "cookies" => [],
      "devicePixelRatio" => 1,
      "chromeExtensions" => [],
      "userChromeExtensions" => [],
      "minResolution" => "800x600",
      "maxResolution" => "7680x4320",
      "uaUserVersion" => "latest",
      "language" => "",
      "folders" => [],
      "webglParams" => {
        "glCanvas" => "webgl2",
        "supportedFunctions" => [
          {
            "name" => "beginQuery",
            "supported" => true
          },
          {
            "name" => "beginTransformFeedback",
            "supported" => true
          },
          {
            "name" => "bindBufferBase",
            "supported" => true
          },
          {
            "name" => "bindBufferRange",
            "supported" => true
          },
          {
            "name" => "bindSampler",
            "supported" => true
          },
          {
            "name" => "bindTransformFeedback",
            "supported" => true
          },
          {
            "name" => "bindVertexArray",
            "supported" => true
          },
          {
            "name" => "blitFramebuffer",
            "supported" => true
          },
          {
            "name" => "clearBufferfi",
            "supported" => true
          },
          {
            "name" => "clearBufferfv",
            "supported" => true
          },
          {
            "name" => "clearBufferiv",
            "supported" => true
          },
          {
            "name" => "clearBufferuiv",
            "supported" => true
          },
          {
            "name" => "clientWaitSync",
            "supported" => true
          },
          {
            "name" => "compressedTexImage3D",
            "supported" => true
          },
          {
            "name" => "compressedTexSubImage3D",
            "supported" => true
          },
          {
            "name" => "copyBufferSubData",
            "supported" => true
          },
          {
            "name" => "copyTexSubImage3D",
            "supported" => true
          },
          {
            "name" => "createQuery",
            "supported" => true
          },
          {
            "name" => "createSampler",
            "supported" => true
          },
          {
            "name" => "createTransformFeedback",
            "supported" => true
          },
          {
            "name" => "createVertexArray",
            "supported" => true
          },
          {
            "name" => "deleteQuery",
            "supported" => true
          },
          {
            "name" => "deleteSampler",
            "supported" => true
          },
          {
            "name" => "deleteSync",
            "supported" => true
          },
          {
            "name" => "deleteTransformFeedback",
            "supported" => true
          },
          {
            "name" => "deleteVertexArray",
            "supported" => true
          },
          {
            "name" => "drawArraysInstanced",
            "supported" => true
          },
          {
            "name" => "drawBuffers",
            "supported" => true
          },
          {
            "name" => "drawElementsInstanced",
            "supported" => true
          },
          {
            "name" => "drawRangeElements",
            "supported" => true
          },
          {
            "name" => "endQuery",
            "supported" => true
          },
          {
            "name" => "endTransformFeedback",
            "supported" => true
          },
          {
            "name" => "fenceSync",
            "supported" => true
          },
          {
            "name" => "framebufferTextureLayer",
            "supported" => true
          },
          {
            "name" => "getActiveUniformBlockName",
            "supported" => true
          },
          {
            "name" => "getActiveUniformBlockParameter",
            "supported" => true
          },
          {
            "name" => "getActiveUniforms",
            "supported" => true
          },
          {
            "name" => "getBufferSubData",
            "supported" => true
          },
          {
            "name" => "getFragDataLocation",
            "supported" => true
          },
          {
            "name" => "getIndexedParameter",
            "supported" => true
          },
          {
            "name" => "getInternalformatParameter",
            "supported" => true
          },
          {
            "name" => "getQuery",
            "supported" => true
          },
          {
            "name" => "getQueryParameter",
            "supported" => true
          },
          {
            "name" => "getSamplerParameter",
            "supported" => true
          },
          {
            "name" => "getSyncParameter",
            "supported" => true
          },
          {
            "name" => "getTransformFeedbackVarying",
            "supported" => true
          },
          {
            "name" => "getUniformBlockIndex",
            "supported" => true
          },
          {
            "name" => "getUniformIndices",
            "supported" => true
          },
          {
            "name" => "invalidateFramebuffer",
            "supported" => true
          },
          {
            "name" => "invalidateSubFramebuffer",
            "supported" => true
          },
          {
            "name" => "isQuery",
            "supported" => true
          },
          {
            "name" => "isSampler",
            "supported" => true
          },
          {
            "name" => "isSync",
            "supported" => true
          },
          {
            "name" => "isTransformFeedback",
            "supported" => true
          },
          {
            "name" => "isVertexArray",
            "supported" => true
          },
          {
            "name" => "pauseTransformFeedback",
            "supported" => true
          },
          {
            "name" => "readBuffer",
            "supported" => true
          },
          {
            "name" => "renderbufferStorageMultisample",
            "supported" => true
          },
          {
            "name" => "resumeTransformFeedback",
            "supported" => true
          },
          {
            "name" => "samplerParameterf",
            "supported" => true
          },
          {
            "name" => "samplerParameteri",
            "supported" => true
          },
          {
            "name" => "texImage3D",
            "supported" => true
          },
          {
            "name" => "texStorage2D",
            "supported" => true
          },
          {
            "name" => "texStorage3D",
            "supported" => true
          },
          {
            "name" => "texSubImage3D",
            "supported" => true
          },
          {
            "name" => "transformFeedbackVaryings",
            "supported" => true
          },
          {
            "name" => "uniform1ui",
            "supported" => true
          },
          {
            "name" => "uniform1uiv",
            "supported" => true
          },
          {
            "name" => "uniform2ui",
            "supported" => true
          },
          {
            "name" => "uniform2uiv",
            "supported" => true
          },
          {
            "name" => "uniform3ui",
            "supported" => true
          },
          {
            "name" => "uniform3uiv",
            "supported" => true
          },
          {
            "name" => "uniform4ui",
            "supported" => true
          },
          {
            "name" => "uniform4uiv",
            "supported" => true
          },
          {
            "name" => "uniformBlockBinding",
            "supported" => true
          },
          {
            "name" => "uniformMatrix2x3fv",
            "supported" => true
          },
          {
            "name" => "uniformMatrix2x4fv",
            "supported" => true
          },
          {
            "name" => "uniformMatrix3x2fv",
            "supported" => true
          },
          {
            "name" => "uniformMatrix3x4fv",
            "supported" => true
          },
          {
            "name" => "uniformMatrix4x2fv",
            "supported" => true
          },
          {
            "name" => "uniformMatrix4x3fv",
            "supported" => true
          },
          {
            "name" => "vertexAttribDivisor",
            "supported" => true
          },
          {
            "name" => "vertexAttribI4i",
            "supported" => true
          },
          {
            "name" => "vertexAttribI4iv",
            "supported" => true
          },
          {
            "name" => "vertexAttribI4ui",
            "supported" => true
          },
          {
            "name" => "vertexAttribI4uiv",
            "supported" => true
          },
          {
            "name" => "vertexAttribIPointer",
            "supported" => true
          },
          {
            "name" => "waitSync",
            "supported" => true
          }
        ],
        "glParamValues" => [
          {
            "name" => "ALIASED_LINE_WIDTH_RANGE",
            "value" => {
              "0" => 1,
              "1" => 7.375
            }
          },
          {
            "name" => "ALIASED_POINT_SIZE_RANGE",
            "value" => {
              "0" => 1,
              "1" => 255
            }
          },
          {
            "name" => [
              "DEPTH_BITS",
              "STENCIL_BITS"
            ],
            "value" => "n/a"
          },
          {
            "name" => "MAX_3D_TEXTURE_SIZE",
            "value" => 2048
          },
          {
            "name" => "MAX_ARRAY_TEXTURE_LAYERS",
            "value" => 2048
          },
          {
            "name" => "MAX_COLOR_ATTACHMENTS",
            "value" => 8
          },
          {
            "name" => "MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS",
            "value" => 262143
          },
          {
            "name" => "MAX_COMBINED_TEXTURE_IMAGE_UNITS",
            "value" => 192
          },
          {
            "name" => "MAX_COMBINED_UNIFORM_BLOCKS",
            "value" => 90
          },
          {
            "name" => "MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS",
            "value" => 262143
          },
          {
            "name" => "MAX_CUBE_MAP_TEXTURE_SIZE",
            "value" => 4096
          },
          {
            "name" => "MAX_DRAW_BUFFERS",
            "value" => 8
          },
          {
            "name" => "MAX_FRAGMENT_INPUT_COMPONENTS",
            "value" => 128
          },
          {
            "name" => "MAX_FRAGMENT_UNIFORM_BLOCKS",
            "value" => 14
          },
          {
            "name" => "MAX_FRAGMENT_UNIFORM_COMPONENTS",
            "value" => 16383
          },
          {
            "name" => "MAX_FRAGMENT_UNIFORM_VECTORS",
            "value" => 4096
          },
          {
            "name" => "MAX_PROGRAM_TEXEL_OFFSET",
            "value" => 7
          },
          {
            "name" => "MAX_RENDERBUFFER_SIZE",
            "value" => 16384
          },
          {
            "name" => "MAX_SAMPLES",
            "value" => 16
          },
          {
            "name" => "MAX_TEXTURE_IMAGE_UNITS",
            "value" => 32
          },
          {
            "name" => "MAX_TEXTURE_LOD_BIAS",
            "value" => 15
          },
          {
            "name" => "MAX_TEXTURE_SIZE",
            "value" => 4096
          },
          {
            "name" => "MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS",
            "value" => 64
          },
          {
            "name" => "MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS",
            "value" => 4
          },
          {
            "name" => "MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS",
            "value" => 64
          },
          {
            "name" => "MAX_UNIFORM_BLOCK_SIZE",
            "value" => 65536
          },
          {
            "name" => "MAX_UNIFORM_BUFFER_BINDINGS",
            "value" => 89
          },
          {
            "name" => "MAX_VARYING_COMPONENTS",
            "value" => 127
          },
          {
            "name" => "MAX_VARYING_VECTORS",
            "value" => 32
          },
          {
            "name" => "MAX_VERTEX_ATTRIBS",
            "value" => 16
          },
          {
            "name" => "MAX_VERTEX_OUTPUT_COMPONENTS",
            "value" => 64
          },
          {
            "name" => "MAX_VERTEX_TEXTURE_IMAGE_UNITS",
            "value" => 32
          },
          {
            "name" => "MAX_VERTEX_UNIFORM_BLOCKS",
            "value" => 14
          },
          {
            "name" => "MAX_VERTEX_UNIFORM_COMPONENTS",
            "value" => 16383
          },
          {
            "name" => "MAX_VERTEX_UNIFORM_VECTORS",
            "value" => 4096
          },
          {
            "name" => "MAX_VIEWPORT_DIMS",
            "value" => {
              "0" => 16384,
              "1" => 16384
            }
          },
          {
            "name" => "MIN_PROGRAM_TEXEL_OFFSET",
            "value" => -8
          },
          {
            "name" => [
              "RED_BITS",
              "GREEN_BITS",
              "BLUE_BITS",
              "ALPHA_BITS"
            ],
            "value" => "n/a"
          },
          {
            "name" => "RENDERER",
            "value" => "WebKit WebGL"
          },
          {
            "name" => "SHADING_LANGUAGE_VERSION",
            "value" => "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)"
          },
          {
            "name" => "UNIFORM_BUFFER_OFFSET_ALIGNMENT",
            "value" => 32
          },
          {
            "name" => "VENDOR",
            "value" => "WebKit"
          },
          {
            "name" => "VERSION",
            "value" => "WebGL 2.0 (OpenGL ES 3.0 Chromium)"
          }
        ],
        "antialiasing" => true,
        "textureMaxAnisotropyExt" => 16,
        "shaiderPrecisionFormat" => "highp/highp",
        "extensions" => [
          "EXT_color_buffer_float",
          "EXT_color_buffer_half_float",
          "EXT_float_blend",
          "EXT_texture_compression_bptc",
          "EXT_texture_compression_rgtc",
          "EXT_texture_filter_anisotropic",
          "EXT_texture_norm16",
          "OES_texture_float_linear",
          "WEBGL_compressed_texture_astc",
          "WEBGL_compressed_texture_etc",
          "WEBGL_compressed_texture_etc1",
          "WEBGL_compressed_texture_s3tc",
          "WEBGL_compressed_texture_s3tc_srgb",
          "WEBGL_debug_renderer_info",
          "WEBGL_debug_shaders",
          "WEBGL_lose_context",
          "WEBGL_multi_draw"
        ]
      },
      "chromeExtensionsToNewProfiles" => [],
      "userChromeExtensionsToNewProfiles" => [],
      "newStartupUrlLogic" => true
    })
    req_options = { use_ssl: uri.scheme == "https", }

    begin
      # puts "updating #{gologin_profile_name} status:#{status}"
      puts "create profile      *****     "
      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      body = JSON.parse(response.body)

      if response.code.to_i == 200
        self.update(gologin_profile_id: body['id'])
      end
    rescue
      puts "error creating profile"
    end
  end

  def sync_gologin
    uri = URI.parse("https://api.gologin.com/browser/#{gologin_profile_id}")
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "*/*"
    request["Authorization"] = "Bearer #{user.gologin_api_token}"
    request["Connection"] = "keep-alive"

    req_options = {
      use_ssl: uri.scheme == "https",
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end
    body = JSON.parse(response.body)

    # if body["statusCode"] == 404 && body["message"] == "Profile has been deleted"
    #   if self.proxy_username != nil && self.proxy_password != nil
    #     self.create_profile
    #     self.create_proxy
    #   else
    #     self.update!(status: 'profile_deleted') and return if self.id
    #   end
    # end

    before_name = gologin_profile_name
    if gologin_profile_name == nil
      self.gologin_profile_name = body["name"]
    end

    if ENV['DEBUG']
      if before_name != body["name"]
        puts "PROFILE #{id} NAME CHANGED: '#{before_name}' -> '#{body["name"]}'"
      elsif body["name"].nil?
        puts "PROFILE #{id} NAME IS NULL???"
      else
        puts "PROFILE #{id} SYNCED"
      end
    end

    self.os = body["os"]
    if body["navigator"]
      self.user_agent = body["navigator"]["userAgent"]
      self.resolution = body["navigator"]["resolution"]
      self.language = body["navigator"]["language"]
    end

    proxy = body['proxy']
    if proxy
      self.proxy_mode = proxy['mode']
      self.proxy_host = proxy['host']
      self.proxy_port = proxy['port']
      self.proxy_username = proxy['username']
      self.proxy_password = proxy['password']
      self.proxy_auto_region = proxy['autoProxyRegion']
      self.proxy_tor_region = proxy['torProxyRegion']
    end
    self.gologin_synced_at = Time.zone.now
    self.touch unless self.new_record?
    self.save(validate: false)

    if body["name"] != nil && before_name != body["name"]
      begin
        update_gologin_name
      rescue => e
        puts e
        puts "ERROR UPDATING GOLOGIN NAME FOR ROBERT"
      end
    end
  end

  def update_proxy_information
    s = Geocoder.search(proxy_ip).try(:first)
    return unless s.try(:city)
    puts "updating proxy" if ENV['DEBUG']
    self.proxy_city =  s.try(:city)
    self.proxy_region = s.region
    self.proxy_org = s.data["org"]
  end

  def self.update_accounts(user)
    user.gologin_profiles.each do |k,v|
      v.each do |e|
        query = where(gologin_profile_id: e)
        name = sync_gologin(e)
        # require 'pry'; binding.pry

        begin
          if query.exists?
            record = query.first
            record.update(
              gologin_folder: k,
              gologin_profile_name: name,
            )
          else
            create!(
              gologin_folder: k,
              gologin_profile_id: e,
              gologin_profile_name: name,
              user: user,
            )
          end
        rescue
          next
        end
      end
    end
  end
end
