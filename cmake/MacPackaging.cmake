# macOS packaging: app bundle, Info.plist, and code signing.
# Owned by the macOS port; included only when APPLE.

set(OMASNAP_MACOS_BUNDLE_ID "org.omasnap.Omasnap" CACHE STRING "omasnap bundle identifier")
set(OMASNAP_SIGN_IDENTITY "" CACHE STRING "Codesign identity for the omasnap.app bundle (empty = ad-hoc or auto-detected omasnap-dev)")

set_target_properties(omasnap PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "omasnap"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${OMASNAP_MACOS_BUNDLE_ID}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
)

# RegisterEventHotKey lives in the Carbon umbrella.
target_link_libraries(omasnap PRIVATE "-framework Carbon")

if(NOT OMASNAP_SIGN_IDENTITY)
  # Prefer a stable self-signed identity (scripts/macos-dev-cert.sh): ad-hoc
  # signatures change on every rebuild, which invalidates the Screen Recording
  # TCC grant each time.
  execute_process(
    COMMAND security find-identity -v -p codesigning
    OUTPUT_VARIABLE _omasnap_identities
    ERROR_QUIET
  )
  if(_omasnap_identities MATCHES "\"omasnap-dev\"")
    set(OMASNAP_SIGN_IDENTITY "omasnap-dev" CACHE STRING
        "Codesign identity for the omasnap.app bundle" FORCE)
    message(STATUS "omasnap: signing with stable identity \"omasnap-dev\"")
  else()
    message(STATUS
        "omasnap: ad-hoc signing; run scripts/macos-dev-cert.sh once so the "
        "Screen Recording grant survives rebuilds")
  endif()
endif()

if(OMASNAP_SIGN_IDENTITY)
  set(_omasnap_codesign_identity "${OMASNAP_SIGN_IDENTITY}")
else()
  set(_omasnap_codesign_identity "-")
endif()
add_custom_command(TARGET omasnap POST_BUILD
  COMMAND codesign --force --sign "${_omasnap_codesign_identity}"
          "$<TARGET_BUNDLE_CONTENT_DIR:omasnap>/.."
  VERBATIM
)
