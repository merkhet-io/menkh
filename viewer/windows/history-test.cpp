#include "History.hpp"
#include <iostream>
int main(int argc, char **argv) {
    try {
        if (argc != 2 && argc != 3)
            throw std::runtime_error("Expected history JSON");
        menkh::History h(std::filesystem::u8path(argv[1]));
        h.verify();
        if(argc==3){h.verifyExposureOracle(std::filesystem::u8path(argv[2]));std::cout<<"Exposure oracle verified forward/backward/forward\n";}
        std::cout << "History verified: " << h.steps.size() << " frames, " << h.initial << " -> "
                  << h.final << " occupied\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
