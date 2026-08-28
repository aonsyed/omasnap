cmake_minimum_required(VERSION 3.24)
project(omasnap VERSION 1.17.2 LANGUAGES C CXX)
include(GNUInstallDirs)
include(CTest)
set(CMAKE_AUTOMOC ON)

find_package(PkgConfig REQUIRED)
find_package(Qt6 6.8 REQUIRED COMPONENTS Concurrent Core Gui Test Widgets)

option(OMASNAP_ENABLE_COVERAGE "Instrument the build for gcov coverage" OFF)
if(OMASNAP_ENABLE_COVERAGE)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    add_compile_options(--coverage)
    add_link_options(--coverage)
  else()
    message(WARNING "OMASNAP_ENABLE_COVERAGE requires GCC; ignoring")
  endif()
endif()

if(APPLE)
  enable_language(OBJCXX)
  set(OMASNAP_PLATFORM_SOURCES
    src/capture-macos.mm
    src/clipboard-macos.mm
    src/notify-macos.mm
    src/ocr-macos.mm
    src/overlay-window-macos.mm
  )
else()
  find_package(LayerShellQt REQUIRED)
  pkg_check_modules(WaylandClient REQUIRED IMPORTED_TARGET wayland-client)
  find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

  set(PROTOCOL_XMLS
    # ext-image-capture-source references this interface even for output-only use.
    /usr/share/wayland-protocols/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml
    /usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml
    /usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml
  )
  set(PROTOCOL_SOURCES)
  foreach(PROTOCOL_XML IN LISTS PROTOCOL_XMLS)
    get_filename_component(PROTOCOL_NAME "${PROTOCOL_XML}" NAME_WE)
    set(PROTOCOL_HEADER "${CMAKE_CURRENT_BINARY_DIR}/${PROTOCOL_NAME}-client-protocol.h")
    set(PROTOCOL_CODE "${CMAKE_CURRENT_BINARY_DIR}/${PROTOCOL_NAME}-protocol.c")
    add_custom_command(
      OUTPUT "${PROTOCOL_HEADER}" "${PROTOCOL_CODE}"
      COMMAND "${WAYLAND_SCANNER}" client-header "${PROTOCOL_XML}" "${PROTOCOL_HEADER}"
      COMMAND "${WAYLAND_SCANNER}" private-code "${PROTOCOL_XML}" "${PROTOCOL_CODE}"
      DEPENDS "${PROTOCOL_XML}"
      VERBATIM
    )
    list(APPEND PROTOCOL_SOURCES "${PROTOCOL_HEADER}" "${PROTOCOL_CODE}")
  endforeach()

  set(OMASNAP_PLATFORM_SOURCES
    src/capture-linux.cpp
    src/overlay-window-wayland.cpp
    src/surface-capture.cpp
    ${PROTOCOL_SOURCES}
  )
endif()

add_library(omasnap-core STATIC
  src/cli-path.cpp
  src/cli-path.hpp
  src/crash-reporter.cpp
  src/crash-reporter.hpp
  src/feature-flags.cpp
  src/feature-flags.hpp
  src/icons.cpp
  src/icons.hpp
  src/instance-lock.cpp
  src/instance-lock.hpp
  src/pin-file.cpp
  src/pin-file.hpp
  src/pin-layout.cpp
  src/pin-layout.hpp
  src/capture.cpp
  src/capture.hpp
  src/capture-platform.hpp
  src/cut.cpp
  src/cut.hpp
  src/palette-config.cpp
  src/palette-config.hpp
  src/eyedropper.cpp
  src/eyedropper.hpp
  src/editor.cpp
  src/editor.hpp
  src/overlay-window.hpp
  src/telemetry.cpp
  src/telemetry.hpp
  ${OMASNAP_PLATFORM_SOURCES}
)
qt_add_resources(omasnap-core "capture-fonts"
  PREFIX "/fonts"
  BASE "${CMAKE_CURRENT_SOURCE_DIR}/assets"
  FILES "${CMAKE_CURRENT_SOURCE_DIR}/assets/Neucha.ttf"
)

target_include_directories(omasnap-core PUBLIC
  "${CMAKE_CURRENT_BINARY_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
target_compile_features(omasnap-core PUBLIC cxx_std_23)
target_compile_options(omasnap-core PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(omasnap-core PUBLIC
  Qt6::Concurrent
  Qt6::Core
  Qt6::Gui
  Qt6::Widgets
)
if(NOT APPLE)
  target_link_libraries(omasnap-core PUBLIC PkgConfig::WaylandClient)
else()
  target_link_libraries(omasnap-core PUBLIC
    "-framework Foundation"
    "-framework AppKit"
    "-framework CoreGraphics"
    "-framework ScreenCaptureKit"
  )
endif()

add_executable(omasnap src/main.cpp src/pin.cpp src/pin.hpp)
target_compile_options(omasnap PRIVATE -Wall -Wextra -Wpedantic)
target_compile_definitions(omasnap PRIVATE OMASNAP_VERSION="${PROJECT_VERSION}")
target_link_libraries(omasnap PRIVATE omasnap-core)
if(NOT APPLE)
  target_link_libraries(omasnap PRIVATE LayerShellQt::Interface)
else()
  include(cmake/MacPackaging.cmake)
  target_sources(omasnap PRIVATE src/serve.cpp src/hotkeys-macos.mm)
endif()

if(BUILD_TESTING)
set(OMASNAP_SMOKE_SOURCES
  tests/editor-smoke.cpp
  tests/clipboard-smoke.cpp
  tests/clipboard-smoke.hpp
  tests/feature-flags-smoke.cpp
  tests/feature-flags-smoke.hpp
  tests/instance-lock-smoke.cpp
  tests/instance-lock-smoke.hpp
  tests/transform-smoke.cpp
  tests/transform-smoke.hpp
  tests/cut-smoke.cpp
  tests/cut-smoke.hpp
  tests/palette-config-smoke.cpp
  tests/palette-config-smoke.hpp
  tests/pin-lifecycle-smoke.cpp
  tests/pin-lifecycle-smoke.hpp
  tests/pin-layout-smoke.cpp
  tests/pin-layout-smoke.hpp
  tests/telemetry-smoke.cpp
  tests/telemetry-smoke.hpp
)
if(NOT APPLE)
  list(APPEND OMASNAP_SMOKE_SOURCES
    tests/surface-capture-smoke.cpp
    tests/surface-capture-smoke.hpp
  )
endif()
add_executable(omasnap-smoke ${OMASNAP_SMOKE_SOURCES})
target_include_directories(omasnap-smoke PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/tests"
)
target_compile_options(omasnap-smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(omasnap-smoke PRIVATE omasnap-core Qt6::Test)
add_test(NAME omasnap-smoke COMMAND omasnap-smoke "${CMAKE_CURRENT_BINARY_DIR}/omasnap-smoke-output")
# The aggregate test drives the whole interaction flow; the standalone suites
# are registered individually so ctest can run them in parallel and in
# randomized order (--parallel, --schedule-random).
set(OMASNAP_SMOKE_TEST_NAMES omasnap-smoke)
foreach(OMASNAP_SUITE IN ITEMS
    clipboard transform cut palette instance-lock pin-layout pin-lifecycle
    feature-flags telemetry)
  list(APPEND OMASNAP_SMOKE_TEST_NAMES omasnap-smoke-${OMASNAP_SUITE})
  add_test(NAME omasnap-smoke-${OMASNAP_SUITE}
    COMMAND omasnap-smoke "${CMAKE_CURRENT_BINARY_DIR}/omasnap-smoke-output" ${OMASNAP_SUITE})
endforeach()
set_tests_properties(${OMASNAP_SMOKE_TEST_NAMES} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()

install(TARGETS omasnap
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
  BUNDLE DESTINATION "${CMAKE_INSTALL_BINDIR}"
)
install(FILES assets/OFL.txt
  DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/omasnap"
  RENAME Neucha-OFL.txt
)
if(NOT APPLE)
install(FILES omasnap.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/applications"
)
endif()
