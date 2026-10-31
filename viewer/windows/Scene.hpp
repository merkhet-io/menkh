#pragma once
#include "History.hpp"
#include <set>
namespace menkh {
struct SceneSelection { fs::path history; std::string id; std::array<double,3> translation; };
inline SceneSelection selectScene(const fs::path &manifest,const std::string &requested) {
    const auto scene=Json::parse(read(manifest,64<<20));
    require(scene.at("format")=="menkh-scene-result-v1" && scene.at("units")=="mm","Invalid scene result");
    const auto &results=scene.at("results"), &objects=scene.at("objects");
    require(results.is_array() && !results.empty() && objects.is_array(),"Invalid scene objects");
    std::set<std::string> ids, objectIds;
    for(const auto &object:objects)require(objectIds.insert(object.at("id").get<std::string>()).second,"Duplicate scene object ID");
    const Json *selected=nullptr;
    for(const auto &result:results) {
        auto id=result.at("object_id").get<std::string>();require(ids.insert(id).second,"Duplicate scene result ID");
        auto object=std::find_if(objects.begin(),objects.end(),[&](const Json &v){return v.at("id")==id;});
        require(object!=objects.end() && object->at("role")=="workpiece" && object->at("translation_mm")==result.at("translation_mm"),"Invalid scene workpiece binding");
        require(result.at("translation_mm").is_array() && result.at("translation_mm").size()==3,"Invalid scene translation");
        for(const auto &v:result.at("translation_mm"))require(v.is_number() && std::isfinite(v.get<double>()),"Invalid scene translation");
        if(id==requested || (requested.empty() && results.size()==1))selected=&result;
    }
    require(selected!=nullptr,"Choose a scene workpiece with --workpiece ID");
    const auto relative=selected->at("history").get<std::string>();
    require(!relative.empty() && relative.find('\\')==std::string::npos && relative.find(':')==std::string::npos,"Invalid scene history path");
    fs::path path=fs::u8path(relative);require(!path.is_absolute(),"Scene history must be relative");
    for(const auto &part:path)require(part!=".." && part!="." && !part.empty(),"Invalid scene history path");
    const auto root=fs::weakly_canonical(manifest.parent_path()), resolved=fs::weakly_canonical(root/path);
    const auto local=resolved.lexically_relative(root);require(!local.empty() && *local.begin()!="..","Scene history escapes result directory");
    return {resolved,selected->at("object_id").get<std::string>(),selected->at("translation_mm").get<std::array<double,3>>()};
}
}
