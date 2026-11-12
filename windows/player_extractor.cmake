# The optional full player is a 7z archive. Ship the exact executable checked
# by WindowsPlayerComponents, in both installed and portable x64 runtimes.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-x64")
  set(ASTERLINK_PLAYER_EXTRACTOR
    "${CMAKE_CURRENT_LIST_DIR}/../native/third_party/player-7za-x64-26.01.bin")
  if(NOT EXISTS "${ASTERLINK_PLAYER_EXTRACTOR}")
    message(FATAL_ERROR "The pinned player component extractor is missing.")
  endif()
  file(SIZE "${ASTERLINK_PLAYER_EXTRACTOR}" ASTERLINK_PLAYER_EXTRACTOR_BYTES)
  file(SHA256 "${ASTERLINK_PLAYER_EXTRACTOR}" ASTERLINK_PLAYER_EXTRACTOR_HASH)
  if(NOT ASTERLINK_PLAYER_EXTRACTOR_BYTES EQUAL 1335296 OR
      NOT ASTERLINK_PLAYER_EXTRACTOR_HASH STREQUAL
        "5bea5af5215089d97749d438351d7288310d0b8a472616edbe1b34168ad1001c")
    message(FATAL_ERROR "The pinned player component extractor did not verify.")
  endif()
  install(PROGRAMS "${ASTERLINK_PLAYER_EXTRACTOR}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/tools"
    RENAME player-7za.exe COMPONENT Runtime)
endif()
