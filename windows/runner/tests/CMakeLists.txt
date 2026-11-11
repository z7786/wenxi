cmake_minimum_required(VERSION 3.14)
project(asterlink_keepalive_tests LANGUAGES CXX)
enable_testing()
add_executable(download_power_request_test
  download_power_request_test.cpp
  ../download_power_request.cpp
)
target_compile_features(download_power_request_test PRIVATE cxx_std_17)
target_compile_definitions(download_power_request_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(download_power_request_test PRIVATE /W4 /WX /utf-8)
add_test(NAME download_power_request COMMAND download_power_request_test)

add_executable(player_image_data_test player_image_data_test.cpp)
target_compile_features(player_image_data_test PRIVATE cxx_std_17)
target_compile_definitions(player_image_data_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(player_image_data_test PRIVATE /W4 /WX /utf-8)
add_test(NAME player_image_data COMMAND player_image_data_test)

add_executable(external_download_request_test external_download_request_test.cpp)
target_compile_features(external_download_request_test PRIVATE cxx_std_17)
target_compile_definitions(external_download_request_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(external_download_request_test PRIVATE /W4 /WX /utf-8)
add_test(NAME external_download_request COMMAND external_download_request_test)

add_executable(gpu_preference_test gpu_preference_test.cpp ../gpu_preference.cpp)
target_compile_features(gpu_preference_test PRIVATE cxx_std_17)
target_compile_definitions(gpu_preference_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(gpu_preference_test PRIVATE /W4 /WX /EHsc /utf-8)
target_link_libraries(gpu_preference_test PRIVATE advapi32.lib)
add_test(NAME gpu_preference COMMAND gpu_preference_test)

if(ASTERLINK_MPV_INTERFACE)
  add_executable(player_component_loading_test player_component_loading_test.cpp)
  target_compile_features(player_component_loading_test PRIVATE cxx_std_17)
  target_compile_options(player_component_loading_test PRIVATE /W4 /WX /utf-8)
  target_include_directories(player_component_loading_test PRIVATE "${ASTERLINK_MPV_INTERFACE}/include")
  target_link_libraries(player_component_loading_test PRIVATE "${ASTERLINK_MPV_INTERFACE}/libmpv.dll.a" delayimp.lib)
  target_link_options(player_component_loading_test PRIVATE "/DELAYLOAD:libmpv-2.dll")
endif()
